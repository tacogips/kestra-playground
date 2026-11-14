/* @refresh reload */
import { render } from "solid-js/web";
import "bulma/css/bulma.min.css";
import "./styles.css";
import { App } from "./App";

render(() => <App />, document.getElementById("root")!);
