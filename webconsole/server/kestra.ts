import type { KestraConfig } from "./config";

export interface ExecutionSummary {
  id: string;
  flowId: string;
  namespace: string;
  state: string;
  startDate: string | null;
  endDate: string | null;
  durationSeconds: number | null;
}

export class KestraApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
  ) {
    super(`Kestra API responded with HTTP ${status}: ${body.slice(0, 300)}`);
  }
}

export class KestraClient {
  constructor(private readonly config: KestraConfig) {}

  private apiUrl(path: string): string {
    return `${this.config.baseUrl}/api/v1/${this.config.tenant}${path}`;
  }

  private headers(): Record<string, string> {
    const headers: Record<string, string> = {};
    if (this.config.username !== "" && this.config.password !== "") {
      const token = Buffer.from(
        `${this.config.username}:${this.config.password}`,
      ).toString("base64");
      headers["Authorization"] = `Basic ${token}`;
    }
    return headers;
  }

  private async request(path: string, init: RequestInit = {}): Promise<Response> {
    const response = await fetch(this.apiUrl(path), {
      ...init,
      headers: { ...this.headers(), ...(init.headers as Record<string, string>) },
    });
    if (!response.ok) {
      throw new KestraApiError(response.status, await response.text());
    }
    return response;
  }

  async triggerFlow(
    flowId: string,
    inputs: Record<string, string>,
  ): Promise<ExecutionSummary> {
    if (!this.config.flowIds.includes(flowId)) {
      throw new Error(`Flow is not allowed by KESTRA_FLOW_IDS: ${flowId}`);
    }
    const form = new FormData();
    for (const [key, value] of Object.entries(inputs)) {
      form.append(key, value);
    }
    const bundlePath = this.config.flowBundles[flowId];
    if (bundlePath !== undefined) {
      const bundle = Bun.file(bundlePath);
      if (!(await bundle.exists())) {
        throw new Error(`Bundle file for flow ${flowId} not found: ${bundlePath}`);
      }
      form.append("batch_bundle", bundle, bundlePath.split("/").pop() ?? "bundle.tar.gz");
    }
    const response = await this.request(
      `/executions/${this.config.namespace}/${flowId}`,
      { method: "POST", body: form },
    );
    return toExecutionSummary(await response.json());
  }

  async listRecentExecutions(size: number): Promise<ExecutionSummary[]> {
    const query = new URLSearchParams({
      namespace: this.config.namespace,
      size: String(size),
      page: "1",
      sort: "state.startDate:desc",
    });
    const response = await this.request(`/executions/search?${query}`);
    const payload = (await response.json()) as { results?: unknown[] };
    return (payload.results ?? []).map(toExecutionSummary);
  }

  async fetchLogs(executionId: string): Promise<string> {
    const response = await this.request(`/logs/${executionId}/download`);
    return response.text();
  }
}

function toExecutionSummary(raw: unknown): ExecutionSummary {
  const execution = raw as {
    id: string;
    flowId: string;
    namespace: string;
    state?: { current?: string; startDate?: string; endDate?: string; duration?: string };
  };
  const startDate = execution.state?.startDate ?? null;
  const endDate = execution.state?.endDate ?? null;
  let durationSeconds: number | null = null;
  if (startDate !== null && endDate !== null) {
    durationSeconds = (Date.parse(endDate) - Date.parse(startDate)) / 1000;
  }
  return {
    id: execution.id,
    flowId: execution.flowId,
    namespace: execution.namespace,
    state: execution.state?.current ?? "UNKNOWN",
    startDate,
    endDate,
    durationSeconds,
  };
}
