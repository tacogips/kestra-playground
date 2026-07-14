export interface Me {
  email: string;
  namespace: string;
  flowIds: string[];
  kestraUrl: string;
}

export interface ExecutionSummary {
  id: string;
  flowId: string;
  namespace: string;
  state: string;
  startDate: string | null;
  endDate: string | null;
  durationSeconds: number | null;
}

export class UnauthenticatedError extends Error {}

async function handle(response: Response): Promise<Response> {
  if (response.status === 401) {
    throw new UnauthenticatedError();
  }
  if (!response.ok) {
    const body = (await response.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? `Request failed with HTTP ${response.status}`);
  }
  return response;
}

export async function fetchMe(): Promise<Me> {
  const response = await handle(await fetch("/api/me"));
  return response.json();
}

export async function fetchExecutions(): Promise<ExecutionSummary[]> {
  const response = await handle(await fetch("/api/executions"));
  const payload = (await response.json()) as { executions: ExecutionSummary[] };
  return payload.executions;
}

export async function triggerExecution(
  flowId: string,
  inputs: Record<string, string>,
): Promise<ExecutionSummary> {
  const response = await handle(
    await fetch("/api/executions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ flowId, inputs }),
    }),
  );
  const payload = (await response.json()) as { execution: ExecutionSummary };
  return payload.execution;
}

export async function fetchLogs(executionId: string): Promise<string> {
  const response = await handle(await fetch(`/api/executions/${executionId}/logs`));
  return response.text();
}
