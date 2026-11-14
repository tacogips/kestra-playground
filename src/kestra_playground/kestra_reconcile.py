"""Safely reconcile one category-owned Kestra namespace from Git."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, cast
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

import yaml


class ReconcileError(RuntimeError):
    """Raised when reconciliation cannot proceed safely."""


@dataclass(frozen=True)
class CategoryManifest:
    """Deployment boundary for one category namespace."""

    id: str
    release_tag_prefix: str
    flow_directory: Path
    namespace: str
    deployment_owner: str
    environment: str
    max_deletes: int


@dataclass(frozen=True)
class FlowDefinition:
    """A validated local or remote Flow source."""

    id: str
    namespace: str
    source: str
    source_hash: str
    deployment_owner: str | None


@dataclass(frozen=True)
class ReconcilePlan:
    """Deterministic differences between Git and Kestra."""

    create: tuple[str, ...]
    update: tuple[str, ...]
    delete: tuple[str, ...]
    unchanged: tuple[str, ...]

    def as_dict(self) -> dict[str, list[str]]:
        """Return a JSON-serializable representation."""
        return {
            "create": list(self.create),
            "update": list(self.update),
            "delete": list(self.delete),
            "unchanged": list(self.unchanged),
        }


class KestraFlows(Protocol):
    """API boundary used by the reconciler and its tests."""

    def validate_flows(self, flows: tuple[FlowDefinition, ...]) -> None: ...

    def list_flows(self, namespace: str) -> tuple[FlowDefinition, ...]: ...

    def create_flow(self, flow: FlowDefinition) -> None: ...

    def update_flow(self, flow: FlowDefinition) -> None: ...

    def delete_flow(self, namespace: str, flow_id: str) -> None: ...


def _required_string(data: dict[str, object], key: str, manifest_path: Path) -> str:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ReconcileError(f"Manifest {manifest_path} requires non-empty string {key!r}.")
    return value


def load_manifest(manifest_path: Path, repo_root: Path) -> CategoryManifest:
    """Load and validate a category deployment manifest."""
    try:
        raw = yaml.safe_load(manifest_path.read_text())
    except (OSError, yaml.YAMLError) as error:
        raise ReconcileError(f"Unable to read manifest {manifest_path}: {error}") from error
    if not isinstance(raw, dict):
        raise ReconcileError(f"Manifest {manifest_path} must contain a YAML mapping.")

    flow_directory_value = _required_string(raw, "flowDirectory", manifest_path)
    flow_directory = (repo_root / flow_directory_value).resolve()
    resolved_root = repo_root.resolve()
    if not flow_directory.is_relative_to(resolved_root):
        raise ReconcileError("Manifest flowDirectory must remain inside the repository.")

    max_deletes = raw.get("maxDeletes", 10)
    if not isinstance(max_deletes, int) or isinstance(max_deletes, bool) or max_deletes < 0:
        raise ReconcileError(f"Manifest {manifest_path} maxDeletes must be a non-negative integer.")

    return CategoryManifest(
        id=_required_string(raw, "id", manifest_path),
        release_tag_prefix=_required_string(raw, "releaseTagPrefix", manifest_path),
        flow_directory=flow_directory,
        namespace=_required_string(raw, "namespace", manifest_path),
        deployment_owner=_required_string(raw, "deploymentOwner", manifest_path),
        environment=_required_string(raw, "environment", manifest_path),
        max_deletes=max_deletes,
    )


def _parse_flow(source: str, source_name: str) -> FlowDefinition:
    try:
        parsed = yaml.safe_load(source)
    except yaml.YAMLError as error:
        raise ReconcileError(f"Invalid YAML in {source_name}: {error}") from error
    if not isinstance(parsed, dict):
        raise ReconcileError(f"Flow {source_name} must contain a YAML mapping.")
    flow_id = parsed.get("id")
    namespace = parsed.get("namespace")
    if not isinstance(flow_id, str) or not flow_id:
        raise ReconcileError(f"Flow {source_name} requires a non-empty string id.")
    if not isinstance(namespace, str) or not namespace:
        raise ReconcileError(f"Flow {source_name} requires a non-empty string namespace.")
    labels = parsed.get("labels", {})
    if not isinstance(labels, dict):
        raise ReconcileError(f"Flow {source_name} labels must be a mapping.")
    owner = labels.get("deployment.owner")
    if owner is not None and not isinstance(owner, str):
        raise ReconcileError(f"Flow {source_name} deployment.owner must be a string.")
    canonical = yaml.safe_dump(parsed, allow_unicode=True, sort_keys=True)
    return FlowDefinition(
        id=flow_id,
        namespace=namespace,
        source=source.strip() + "\n",
        source_hash=hashlib.sha256(canonical.encode()).hexdigest(),
        deployment_owner=owner,
    )


def load_desired_flows(manifest: CategoryManifest) -> tuple[FlowDefinition, ...]:
    """Load every desired YAML Flow and enforce the manifest boundary."""
    if not manifest.flow_directory.is_dir():
        raise ReconcileError(f"Flow directory does not exist: {manifest.flow_directory}")
    paths = sorted(
        (*manifest.flow_directory.glob("*.yaml"), *manifest.flow_directory.glob("*.yml"))
    )
    if not paths:
        raise ReconcileError(f"Refusing an empty desired Flow directory: {manifest.flow_directory}")

    flows = tuple(_parse_flow(path.read_text(), str(path)) for path in paths)
    ids = [flow.id for flow in flows]
    duplicates = sorted({flow_id for flow_id in ids if ids.count(flow_id) > 1})
    if duplicates:
        raise ReconcileError(f"Duplicate desired Flow IDs: {', '.join(duplicates)}")
    for flow in flows:
        if flow.namespace != manifest.namespace:
            raise ReconcileError(
                f"Flow {flow.id} namespace {flow.namespace!r} does not equal manifest namespace "
                f"{manifest.namespace!r}."
            )
        if flow.deployment_owner != manifest.deployment_owner:
            raise ReconcileError(
                f"Flow {flow.id} must have deployment.owner={manifest.deployment_owner!r}."
            )
        parsed = yaml.safe_load(flow.source)
        labels = parsed["labels"]
        if labels.get("category") != manifest.id:
            raise ReconcileError(f"Flow {flow.id} must have category={manifest.id!r}.")
        if labels.get("environment") != manifest.environment:
            raise ReconcileError(f"Flow {flow.id} must have environment={manifest.environment!r}.")
        read_only = labels.get("system.readOnly")
        if read_only is not True and str(read_only).lower() != "true":
            raise ReconcileError(f"Flow {flow.id} must have system.readOnly=true.")
    return flows


def build_plan(
    manifest: CategoryManifest,
    desired: tuple[FlowDefinition, ...],
    actual: tuple[FlowDefinition, ...],
) -> ReconcilePlan:
    """Build a category-scoped plan and reject foreign server-side ownership."""
    desired_by_id = {flow.id: flow for flow in desired}
    actual_by_id: dict[str, FlowDefinition] = {}
    for flow in actual:
        if flow.namespace != manifest.namespace:
            raise ReconcileError(
                f"Kestra returned Flow {flow.id} outside namespace {manifest.namespace!r}."
            )
        if flow.deployment_owner != manifest.deployment_owner:
            raise ReconcileError(
                f"Refusing to manage {flow.namespace}.{flow.id}: deployment.owner is "
                f"{flow.deployment_owner!r}, expected {manifest.deployment_owner!r}."
            )
        if flow.id in actual_by_id:
            raise ReconcileError(f"Kestra returned duplicate Flow ID {flow.id!r}.")
        actual_by_id[flow.id] = flow

    desired_ids = set(desired_by_id)
    actual_ids = set(actual_by_id)
    common_ids = desired_ids & actual_ids
    return ReconcilePlan(
        create=tuple(sorted(desired_ids - actual_ids)),
        update=tuple(
            sorted(
                flow_id
                for flow_id in common_ids
                if desired_by_id[flow_id].source_hash != actual_by_id[flow_id].source_hash
            )
        ),
        delete=tuple(sorted(actual_ids - desired_ids)),
        unchanged=tuple(
            sorted(
                flow_id
                for flow_id in common_ids
                if desired_by_id[flow_id].source_hash == actual_by_id[flow_id].source_hash
            )
        ),
    )


def reconcile(
    client: KestraFlows,
    manifest: CategoryManifest,
    desired: tuple[FlowDefinition, ...],
    *,
    apply: bool,
    allow_delete: bool,
) -> ReconcilePlan:
    """Plan or apply reconciliation, always deleting stale Flows last."""
    client.validate_flows(desired)
    plan = build_plan(manifest, desired, client.list_flows(manifest.namespace))
    if len(plan.delete) > manifest.max_deletes:
        raise ReconcileError(
            f"Plan deletes {len(plan.delete)} Flows, exceeding maxDeletes={manifest.max_deletes}."
        )
    if apply and plan.delete and not allow_delete:
        raise ReconcileError("The plan contains deletions; rerun apply with --delete.")
    if not apply:
        return plan

    desired_by_id = {flow.id: flow for flow in desired}
    for flow_id in plan.create:
        client.create_flow(desired_by_id[flow_id])
    for flow_id in plan.update:
        client.update_flow(desired_by_id[flow_id])
    for flow_id in plan.delete:
        client.delete_flow(manifest.namespace, flow_id)

    final_plan = build_plan(manifest, desired, client.list_flows(manifest.namespace))
    if final_plan.create or final_plan.update or final_plan.delete:
        raise ReconcileError(
            f"Final Kestra state differs from Git: {json.dumps(final_plan.as_dict())}"
        )
    return plan


class KestraApiClient:
    """Small Basic Auth client for the Kestra OSS Flow API."""

    def __init__(
        self,
        base_url: str,
        tenant: str,
        username: str | None,
        password: str | None,
        *,
        attempts: int = 4,
        retry_delay: float = 2.0,
    ) -> None:
        if bool(username) != bool(password):
            raise ReconcileError(
                "Both Kestra Basic Auth username and password must be set together."
            )
        self._base_url = base_url.rstrip("/")
        self._tenant = quote(tenant, safe="")
        self._attempts = attempts
        self._retry_delay = retry_delay
        self._authorization = None
        if username is not None and password is not None:
            encoded = base64.b64encode(f"{username}:{password}".encode()).decode()
            self._authorization = f"Basic {encoded}"

    def _request(self, method: str, path: str, body: str | None = None) -> object | None:
        data = body.encode() if body is not None else None
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/x-yaml"
        if self._authorization is not None:
            headers["Authorization"] = self._authorization

        last_error = "unknown error"
        for attempt in range(1, self._attempts + 1):
            request = Request(f"{self._base_url}{path}", data=data, headers=headers, method=method)
            try:
                with urlopen(request, timeout=30) as response:  # noqa: S310
                    payload = response.read().decode()
                    if not payload:
                        return None
                    return json.loads(payload)
            except HTTPError as error:
                error_body = error.read().decode(errors="replace")
                last_error = f"HTTP {error.code}: {error_body}"
                retryable = error.code in {408, 409, 429} or error.code >= 500
                if not retryable or attempt == self._attempts:
                    break
            except (URLError, TimeoutError, json.JSONDecodeError) as error:
                last_error = str(error)
                if attempt == self._attempts:
                    break
            time.sleep(self._retry_delay)
        raise ReconcileError(f"Kestra API {method} {path} failed: {last_error}")

    @property
    def _flows_path(self) -> str:
        return f"/api/v1/{self._tenant}/flows"

    def validate_flows(self, flows: tuple[FlowDefinition, ...]) -> None:
        result = self._request(
            "POST", f"{self._flows_path}/validate", "\n---\n".join(flow.source for flow in flows)
        )
        if not isinstance(result, list) or len(result) != len(flows):
            raise ReconcileError("Kestra returned an unexpected Flow validation response.")
        if not all(isinstance(item, dict) for item in result):
            raise ReconcileError("Kestra returned an invalid Flow validation item.")
        validation_items = cast("list[dict[str, object]]", result)
        failures = [item for item in validation_items if item.get("constraints")]
        if failures:
            raise ReconcileError(f"Kestra Flow validation failed: {json.dumps(failures)}")

    def list_flows(self, namespace: str) -> tuple[FlowDefinition, ...]:
        namespace_path = quote(namespace, safe="")
        result = self._request("GET", f"{self._flows_path}/{namespace_path}")
        if not isinstance(result, list):
            raise ReconcileError("Kestra returned an unexpected namespace Flow list.")
        flows: list[FlowDefinition] = []
        for item in result:
            if not isinstance(item, dict):
                raise ReconcileError("Kestra namespace Flow list contains an invalid item.")
            item_mapping = cast("dict[str, object]", item)
            flow_id_value = item_mapping.get("id")
            if not isinstance(flow_id_value, str):
                raise ReconcileError("Kestra namespace Flow list contains an invalid item.")
            flow_id = quote(flow_id_value, safe="")
            detail = self._request(
                "GET", f"{self._flows_path}/{namespace_path}/{flow_id}?source=true"
            )
            if not isinstance(detail, dict):
                raise ReconcileError(f"Kestra did not return source for Flow {flow_id_value}.")
            detail_mapping = cast("dict[str, object]", detail)
            source = detail_mapping.get("source")
            if not isinstance(source, str):
                raise ReconcileError(f"Kestra did not return source for Flow {flow_id_value}.")
            flows.append(_parse_flow(source, f"Kestra:{namespace}.{flow_id_value}"))
        return tuple(flows)

    def create_flow(self, flow: FlowDefinition) -> None:
        self._request("POST", self._flows_path, flow.source)

    def update_flow(self, flow: FlowDefinition) -> None:
        namespace = quote(flow.namespace, safe="")
        flow_id = quote(flow.id, safe="")
        self._request("PUT", f"{self._flows_path}/{namespace}/{flow_id}", flow.source)

    def delete_flow(self, namespace: str, flow_id: str) -> None:
        namespace_path = quote(namespace, safe="")
        flow_id_path = quote(flow_id, safe="")
        self._request("DELETE", f"{self._flows_path}/{namespace_path}/{flow_id_path}")


def validate_release_ref(repo_root: Path, manifest: CategoryManifest, release_ref: str) -> None:
    """Require the release tag to match the manifest and point at checked-out HEAD."""
    pattern = rf"^{re.escape(manifest.release_tag_prefix)}[0-9]+\.[0-9]+\.[0-9]+$"
    if not re.fullmatch(pattern, release_ref):
        raise ReconcileError(
            f"Release ref must match {manifest.release_tag_prefix}X.Y.Z: {release_ref}"
        )
    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        tagged = subprocess.run(
            ["git", "rev-parse", f"{release_ref}^{{commit}}"],
            cwd=repo_root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        raise ReconcileError(f"Unable to resolve release ref {release_ref}: {error}") from error
    if head != tagged:
        raise ReconcileError(
            f"Release ref {release_ref} does not point at checked-out HEAD {head}."
        )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--category", required=True)
    parser.add_argument("--environment", required=True)
    parser.add_argument("--ref", required=True, dest="release_ref")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--plan", action="store_true")
    mode.add_argument("--apply", action="store_true")
    parser.add_argument("--delete", action="store_true", help="Allow guarded stale Flow deletion")
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--url", default=os.getenv("KESTRA_URL"))
    parser.add_argument("--tenant", default=os.getenv("KESTRA_TENANT", "main"))
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run category namespace reconciliation from the command line."""
    args = _parser().parse_args(argv)
    try:
        repo_root = args.repo_root.resolve()
        manifest_path = repo_root / "category-controllers" / args.category / "category.yaml"
        manifest = load_manifest(manifest_path, repo_root)
        if manifest.id != args.category:
            raise ReconcileError(
                f"Manifest id {manifest.id!r} does not match category {args.category!r}."
            )
        if manifest.environment != args.environment:
            raise ReconcileError(
                f"Manifest environment {manifest.environment!r} does not match "
                f"{args.environment!r}."
            )
        if not args.url:
            raise ReconcileError("Set KESTRA_URL or pass --url.")
        validate_release_ref(repo_root, manifest, args.release_ref)
        desired = load_desired_flows(manifest)
        client = KestraApiClient(
            args.url,
            args.tenant,
            os.getenv("KESTRA_BASIC_AUTH_USERNAME"),
            os.getenv("KESTRA_BASIC_AUTH_PASSWORD"),
        )
        plan = reconcile(
            client,
            manifest,
            desired,
            apply=args.apply,
            allow_delete=args.delete,
        )
        result = {
            "category": manifest.id,
            "environment": manifest.environment,
            "namespace": manifest.namespace,
            "ref": args.release_ref,
            "mode": "apply" if args.apply else "plan",
            **plan.as_dict(),
        }
        print(json.dumps(result, sort_keys=True))
        return 0
    except ReconcileError as error:
        print(f"Reconciliation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
