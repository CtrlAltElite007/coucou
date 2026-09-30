# Cloud Work for macOS

This fork adds a Codex-first remote companion while preserving the existing Claude Code hook/socket and Anthropic chat paths. Windows is unchanged.

## What works

- Cloud Work opens from the menu bar, notch cloud button, or permanent Cloud Work pill (the default focus).
- A provider-neutral job/event ledger distinguishes queued, running, needs-attention, completed, failed, cancelled, idle and unknown states. Provider IDs namespace jobs; stale snapshots cannot overwrite newer events. Disconnects mark cached results stale.
- Codex app-server over authenticated WSS: initialize handshake, bounded thread listing, thread inspection, new remote thread/turn handoff, interruption, remote multi-turn notch chat, item and lifecycle events, and command/file approval requests.
- **Sign in with ChatGPT** from the connected personal host: one-time device code, official verification link, cancellation, remote sign-out, account/plan display and usage windows. Credentials are managed by the host; Coucou does not receive OAuth tokens. Login completion and disconnect races are covered by pure model tests.
- Allow once / Deny is explicit, scoped to the connection, request, thread and turn. Multiple approvals are queued independently. No session-wide auto-approval. Requests remain pending until the server confirms resolution. Unsupported requests get a protocol error, never an implicit acceptance.
- Read-only remote hook discovery through hooks/list, plus hook/started and hook/completed events where the remote version emits them. No automatic hook installation or trust bypass.
- GitHub Actions: latest 100 runs for one selected repository, branch/commit/attempt details, real run links, failure/waiting status, and explicit workflow dispatch.
- Browser handoff copies a repository-aware prompt and opens https://chatgpt.com/codex. You still select the repository, paste and submit there; Coucou does not claim it submitted or discovered that browser task.
- Optional macOS completion/failure/attention notifications. Initial GitHub snapshots are quiet.
- Claude compatibility: existing VS Code hook filters, install/backup/confirmation flow and approval socket remain intact. Claude events additionally feed the normalized ledger. Select Claude in Settings to keep the existing Anthropic chat/file/window features.

## Three different integrations

| Path | Runs where | Authentication | Status/approvals |
| --- | --- | --- | --- |
| Remote app-server | Your configured cloud VM/remote host | In-app ChatGPT device-code sign-in (or an existing supported host account), plus a separate WSS bearer token | Listed threads, subscribed events, command/file approvals |
| Hosted Codex browser | OpenAI's configured cloud environment | Your browser's ChatGPT account | Review and approve in the hosted product; no undocumented task API is used |
| GitHub Actions | Runners configured by your workflow | GitHub token with repository Actions access | Run snapshots; external review on GitHub; workflow_dispatch |

The remote app-server is not the hosted Codex task service. Its WebSocket transport is experimental and currently documented as unsupported for production workloads. A ChatGPT subscription is not an Anthropic/OpenAI API key. This implementation does not extract desktop/browser tokens or run the paid Agents API.

## Remote host setup

Do these steps **on a cloud host**, not on the Mac running Coucou:

1. Install a current compatible Codex CLI. You can sign in from Coucou after connecting, or keep an existing supported host login. Provision a repository checkout and its dependencies on that host.
2. Create a high-entropy bearer token file with owner-only permissions. Configure an authenticated app-server, bound to loopback:
   ~~~sh
   codex app-server --listen ws://127.0.0.1:4500 \
     --ws-auth capability-token --ws-token-file /secure/path/app-server-token
   ~~~
3. Put a TLS WebSocket reverse proxy in front of that loopback listener. Preserve the Authorization header. Restrict access to the intended users. Do not expose the unauthenticated listener.
4. In Coucou Settings → Assistant & Cloud Work, save the wss:// endpoint, bearer token and absolute remote checkout directory. The endpoint cannot contain credentials, query parameters or fragments. Secrets are stored only in Keychain. Redirects are rejected.
5. Open Cloud Work and click Connect remote host. Check the Remote account card. If sign-in is required, click Sign in with ChatGPT, open OpenAI sign-in and enter the displayed code. The card updates after the remote host confirms the login. If device sign-in is disabled by your account policy, use the host's supported login client. New work uses workspace-write and on-request approvals; remote managed policy can still reject it. The remote host chooses its configured model. No model entitlement is assumed or hard-coded.
6. Enter a task and click Start remote task, or use the notch chat.

This app-server authentication integration is for a personal/open-source companion and a user-controlled host. It is not authentication for a commercial or hosted multi-user service. Those integrations need the supported Sign in with ChatGPT registration/partner path. A WSS connection token protects access to the host; it is distinct from the ChatGPT login. Sign-out affects other clients sharing the same host account and requires an explicit in-app confirmation.

The directory selects the existing remote checkout. A GitHub repository label is prompt context only: it does not clone, verify the remote origin, or switch branches. Check the directory and the returned git metadata before submitting work.

Connection failures and 30-second RPC timeouts do not retry a submission or approval automatically. Work may continue remotely. Reconnect, refresh and inspect the thread before submitting again. Reconnecting resets notch chat; existing threads remain visible for inspection on the remote host.

To inspect configured hooks, connect first, then click Inspect remote hooks in Settings. Hooks must exist and be trusted in their execution environment. Cloud orchestration has different hook support from local/remote app-server execution. This app does not promise personal hosted-cloud shell hooks or automatically modify either provider's settings.

## GitHub setup

Save a GitHub token in the existing Integrations settings. A fine-grained token needs access to the selected repository and Actions read. Actions write is additionally needed only for workflow dispatch. Save owner/repository in Cloud Work settings.

Optional handoff: set the workflow filename and an existing branch/ref. The workflow must already define a string prompt input:

~~~yaml
on:
  workflow_dispatch:
    inputs:
      prompt:
        description: Task to perform
        type: string
        required: true
~~~

The workflow owner defines what executes and which credentials it uses. When implementing a workflow, pass untrusted prompt text through an environment variable or a data file, never interpolate it into shell source. Coucou does not install a paid agent workflow, provision credentials, or bypass environment protection.

Run GitHub workflow shows the repository/workflow/ref confirmation. A successful dispatch means GitHub accepted it; GitHub's 204 response does not contain a run ID. Refresh to find the actual run. A successful CI run is not proof of deployment.

## Architecture

- WorkModels.swift: Sendable provider/job/event/approval contracts, URL/context validation and pure bounded reducer.
- WorkStore.swift: shared observable ledger, opt-in notifications, cloud notch state, Claude hook adapter.
- RemoteAccountModels.swift / RemoteAccountView.swift: account readiness, device-code lifecycle, trusted verification URL, plan/usage display and sign-out confirmation.
- CodexRemoteProvider.swift: remote JSON-RPC transport, handshake, timeouts, request routing, job/approval lifecycle. Numeric and string request IDs remain distinct.
- GitHubWorkProvider.swift: fixed GitHub REST origin, token-backed Actions snapshots and dispatch.
- AssistantService.swift: provider selection and an assistant protocol. Remote chat rejects local file/window attachments; Claude retains those capabilities.
- CloudWorkView.swift: workspace, job details, provider filter, handoff controls, approval queue and settings.
- Existing HookServer.swift continues to own Claude approval replies. Remote approvals never use that socket.

No new third-party runtime dependency. Bundle IDs and existing Keychain service are unchanged. No code is downloaded or executed on the Mac for the remote path.

## Known boundaries and acceptance checks

- No remote host is provisioned by this change. A live compatible endpoint and credentials are required to exercise remote chat, work and approvals.
- Hosted browser tasks are not enumerated by app-server. The Agents API is a separately billed integration and is intentionally not wired to a subscription.
- Thread listing covers up to 200 recent interactive/app-server/exec threads in the configured remote directory. GitHub lists up to 100 recent runs. Cached UI history is bounded to 200 entries across providers.
- Listing/reading a thread does not subscribe to it. Live events/approvals are available for threads this connection starts; other threads refresh as snapshots. Continue existing external threads in their original client. Coucou only interrupts a turn whose ID it has observed.
- Rich user-input forms, permission-expansion requests and MCP elicitation are not supported in this client. They return an explicit unsupported error; use a full client for those workflows. Allow once is disabled when no command/patch/network preview is available.
- GitHub run review/approvals happen on GitHub. No GitHub approval endpoint is invented.
- Refresh occurs on opening Cloud Work, on demand, and every 60 seconds while its view is active. There is no background GitHub monitoring when it is closed. Remote subscribed events continue while connected.
- Remote chat is text-only and scoped to the remote checkout. Local attachments are neither read nor uploaded by that path. Choose Claude for the preserved local attachment flow.
- UI history is in memory; server history remains on the remote host. Secrets persist in Keychain; non-secret endpoint/repo preferences use UserDefaults.
- App-server protocol/version compatibility, real credentials, concurrent live approvals, native notification permission, notch layout and sleep/reconnect require an interactive macOS smoke test. No live API or paid inference is required by CI.
- CI compiles pure model/auth checks and both macOS targets without signing. The uploaded ZIP preserves app executable permissions and is unsigned; it is not a signed/notarized release or an App Store submission.

## Validation status

Development and commits were made through GitHub tools, without a local checkout or local builds. On 2026-09-30 the fork had no Actions runs after the commits. The connector had repository write access but no workflow-dispatch tool; the available browser account had read-only access to this fork. Build/test results therefore remain **unverified** until the owner runs the Build workflow on main. No live remote host or model call was used for validation.

## Verified contracts

Reviewed 2026-10-01:

- [Official app-server interface](https://developers.openai.com/codex/app-server): remote transport/auth flags, initialize, threads, turns, items, approvals and hook discovery.
- [Official app-server account interface](https://learn.chatgpt.com/docs/app-server#auth-endpoints): account/read, chatgptDeviceCode, completion/cancellation, logout and rate limits; personal/open-source scope.
- [Official hooks reference](https://learn.chatgpt.com/docs/hooks): supported events, trust and cloud orchestration limits.
- [Thread-start schema](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/json/v2/ThreadStartParams.json): wire values workspace-write and on-request.
- [Agents API](https://developers.openai.com/api/docs/guides/agents-api/overview): managed cloud harness and separate API billing.
- [Sign in with ChatGPT preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations): third-party plan usage is a specific supported authorization flow, not a generic API key.
- [GitHub workflow runs](https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-repository) and [workflow dispatch](https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event).
