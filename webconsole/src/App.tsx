import {
  For,
  Show,
  createResource,
  createSignal,
  onCleanup,
  type Component,
} from "solid-js";
import {
  UnauthenticatedError,
  fetchExecutions,
  fetchLogs,
  fetchMe,
  triggerExecution,
  type ExecutionSummary,
  type Me,
} from "./api";

function todayIsoDate(): string {
  return new Date().toISOString().slice(0, 10);
}

function stateTagClass(state: string): string {
  switch (state) {
    case "SUCCESS":
      return "tag is-success";
    case "FAILED":
      return "tag is-danger";
    case "RUNNING":
      return "tag is-info";
    case "CREATED":
    case "QUEUED":
      return "tag is-warning";
    case "KILLED":
    case "WARNING":
      return "tag is-warning is-light";
    default:
      return "tag";
  }
}

function formatDate(value: string | null): string {
  if (value === null) {
    return "-";
  }
  return new Date(value).toLocaleString();
}

const SignInGate: Component = () => (
  <section class="hero is-fullheight">
    <div class="hero-body">
      <div class="container has-text-centered">
        <h1 class="title">Kestra Batch Console</h1>
        <p class="subtitle">Sign in with your Google account to continue.</p>
        <a class="button is-link is-medium" href="/auth/login">
          Sign in with Google
        </a>
      </div>
    </div>
  </section>
);

export const App: Component = () => {
  const [me] = createResource<Me | null>(async () => {
    try {
      return await fetchMe();
    } catch (error) {
      if (error instanceof UnauthenticatedError) {
        return null;
      }
      throw error;
    }
  });

  return (
    <Show when={me() !== undefined}>
      <Show when={me() !== null} fallback={<SignInGate />}>
        <Console me={me()!} />
      </Show>
    </Show>
  );
};

const Console: Component<{ me: Me }> = (props) => {
  const [executions, { refetch }] = createResource<ExecutionSummary[]>(
    fetchExecutions,
    { initialValue: [] },
  );
  const [selectedFlow, setSelectedFlow] = createSignal(props.me.flowIds[0] ?? "");
  const [businessDate, setBusinessDate] = createSignal(todayIsoDate());
  const [notice, setNotice] = createSignal<{ kind: string; text: string } | null>(null);
  const [triggering, setTriggering] = createSignal(false);
  const [logExecution, setLogExecution] = createSignal<ExecutionSummary | null>(null);
  const [logText, setLogText] = createSignal("");
  const [logLoading, setLogLoading] = createSignal(false);

  const refreshTimer = setInterval(() => void refetch(), 10_000);
  onCleanup(() => clearInterval(refreshTimer));

  const runFlow = async () => {
    setTriggering(true);
    setNotice(null);
    try {
      const execution = await triggerExecution(selectedFlow(), {
        business_date: businessDate(),
      });
      setNotice({
        kind: "is-success",
        text: `Triggered ${execution.flowId} (execution ${execution.id})`,
      });
      await refetch();
    } catch (error) {
      setNotice({ kind: "is-danger", text: (error as Error).message });
    } finally {
      setTriggering(false);
    }
  };

  const openLogs = async (execution: ExecutionSummary) => {
    setLogExecution(execution);
    setLogLoading(true);
    setLogText("");
    try {
      setLogText(await fetchLogs(execution.id));
    } catch (error) {
      setLogText(`Failed to load logs: ${(error as Error).message}`);
    } finally {
      setLogLoading(false);
    }
  };

  return (
    <>
      <nav class="navbar is-dark" role="navigation">
        <div class="navbar-brand">
          <span class="navbar-item has-text-weight-bold">Kestra Batch Console</span>
        </div>
        <div class="navbar-end">
          <span class="navbar-item">{props.me.email}</span>
          <div class="navbar-item">
            <a class="button is-small" href="/auth/logout">
              Sign out
            </a>
          </div>
        </div>
      </nav>

      <section class="section">
        <div class="container">
          <div class="box">
            <h2 class="title is-5">Run batch job</h2>
            <p class="mb-3">
              Namespace: <code>{props.me.namespace}</code> on{" "}
              <code>{props.me.kestraUrl}</code>
            </p>
            <div class="field is-grouped is-grouped-multiline">
              <div class="control">
                <div class="select">
                  <select
                    value={selectedFlow()}
                    onChange={(event) => setSelectedFlow(event.currentTarget.value)}
                  >
                    <For each={props.me.flowIds}>
                      {(flowId) => <option value={flowId}>{flowId}</option>}
                    </For>
                  </select>
                </div>
              </div>
              <div class="control">
                <input
                  class="input"
                  type="date"
                  value={businessDate()}
                  onChange={(event) => setBusinessDate(event.currentTarget.value)}
                />
              </div>
              <div class="control">
                <button
                  class={`button is-primary ${triggering() ? "is-loading" : ""}`}
                  onClick={() => void runFlow()}
                  disabled={triggering() || selectedFlow() === ""}
                >
                  Run
                </button>
              </div>
            </div>
            <Show when={notice() !== null}>
              <div class={`notification ${notice()!.kind}`}>{notice()!.text}</div>
            </Show>
          </div>

          <div class="box">
            <div class="level">
              <div class="level-left">
                <h2 class="title is-5">Latest 10 executions</h2>
              </div>
              <div class="level-right">
                <button class="button is-small" onClick={() => void refetch()}>
                  Refresh
                </button>
              </div>
            </div>
            <table class="table is-fullwidth is-hoverable">
              <thead>
                <tr>
                  <th>Flow</th>
                  <th>Execution</th>
                  <th>State</th>
                  <th>Started</th>
                  <th>Duration</th>
                </tr>
              </thead>
              <tbody>
                <For each={executions()}>
                  {(execution) => (
                    <tr
                      class="execution-row"
                      onClick={() => void openLogs(execution)}
                      title="Click to view logs"
                    >
                      <td>{execution.flowId}</td>
                      <td>
                        <code>{execution.id}</code>
                      </td>
                      <td>
                        <span class={stateTagClass(execution.state)}>
                          {execution.state}
                        </span>
                      </td>
                      <td>{formatDate(execution.startDate)}</td>
                      <td>
                        {execution.durationSeconds !== null
                          ? `${execution.durationSeconds.toFixed(1)}s`
                          : "-"}
                      </td>
                    </tr>
                  )}
                </For>
              </tbody>
            </table>
            <Show when={executions().length === 0}>
              <p class="has-text-grey">No executions yet.</p>
            </Show>
          </div>
        </div>
      </section>

      <div class={`modal ${logExecution() !== null ? "is-active" : ""}`}>
        <div class="modal-background" onClick={() => setLogExecution(null)} />
        <div class="modal-card" style={{ width: "80%" }}>
          <header class="modal-card-head">
            <p class="modal-card-title is-size-6">
              Logs: {logExecution()?.flowId} / <code>{logExecution()?.id}</code>
            </p>
            <button class="delete" onClick={() => setLogExecution(null)} />
          </header>
          <section class="modal-card-body">
            <Show when={!logLoading()} fallback={<progress class="progress is-small" />}>
              <pre class="log-view">{logText() || "(no log lines)"}</pre>
            </Show>
          </section>
        </div>
      </div>
    </>
  );
};
