# Testing ChatGPT subscriptions

ChatGPT access currently uses OpenAI's open-source Sign in with ChatGPT preview. Use an eligible
Plus or Pro account. Account, workspace, region, and usage policies can still restrict access.
No OpenAI API key or Codex installation is needed for this connection.

## Build and launch

Quit any running copy of Dictidy using its menu before launching this build.
From the repository root:

```sh
swift run DictidyTests
./Scripts/test-chatgpt-platform.sh
./Scripts/build-app.sh debug
open ./Dictidy.app
```

Use your existing stable signing identity. If you have never configured one, run
`./Scripts/setup-signing.sh` before building. Grant Accessibility if macOS asks; dictation also
needs Microphone access and the local speech model. Avoid accepting an in-app update during these
tests, because it replaces the development build with the published release.

The normal test runner uses synthetic credentials and injected transports. It checks OAuth callback
validation, identity claims, catalog parsing, subscription request fields, billing/account isolation,
stream completion, usage errors, cancellation, and existing API-key behavior. It makes no paid requests.
The platform checks additionally exercise the real loopback listener and verify RSA signatures with
ephemeral test keys using Security.framework. They do not read or change your saved account.

## Acceptance checklist

1. **Connect from settings.** Open **Settings → Rewrite** and click **Continue with ChatGPT**.
   In your browser, sign in, choose the intended workspace if offered, and allow Dictidy to use
   your plan. Return to Dictidy. Expect a first-use confirmation, the connected account, and loaded
   models. Cancel once before completing a login to verify that **Cancel sign-in** works.

2. **Choose subscription billing explicitly.** In **Default model**, select a model under
   **ChatGPT plan**. Expect **Using ChatGPT plan** beside **Manage usage**. Existing Anthropic or
   OpenAI API-key selections remain selected until you change them. You can keep your keys saved;
   you do not need to remove them to test subscription access.

3. **Rewrite a selection.** In Notes or TextEdit, type and select:

   > hey alex i finished the draft can you take a look tomorrow thanks

   Trigger Auto Clean with **Shift-Command-R**. Expect a complete rewrite in place, preserving the
   meaning. Check **History** and **Paste Last Text**. Try an instruction with an explicit ChatGPT
   model override, then **History → Rewrite again**. If dictation is configured, also test
   **Dictate + Clean** with that instruction.

4. **Check usage.** Click **Manage usage**. Expect ChatGPT's usage settings, where you can inspect
   Dictidy's registration, plan allowance, and permission to use ChatGPT credits. Usage reporting
   may take time to update. This connection uses your plan or permitted ChatGPT credits; OpenAI
   API-key billing is a separate choice in Dictidy.

5. **Check persistence and renewal.** Quit and reopen Dictidy, then rewrite again. Expect the same
   account and model without another browser login. To exercise token renewal, leave the account
   connected for over an hour and rewrite again. Expect automatic renewal unless the session has
   been revoked or the provider requires sign-in again.

6. **Check sign-out and reconnection.** Keep an API key saved, select a ChatGPT plan model, and click
   **Sign Out**. Expect the ChatGPT model to become unavailable; a rewrite must not run using the
   saved API key. Reconnect the same saved account and verify that its model becomes available
   again. **Add account** can register another account/workspace; switching accounts must make an
   override for the previous account unavailable until you choose a model for the active account.

7. **Check recovery.** Turn off network access and try a rewrite. Expect an error and unchanged
   selected text. Restore the network and retry. Press Escape during a longer rewrite; no partial
   or late output should paste. If a real plan limit occurs, expect a usage message and unchanged
   text; use **Manage usage** to inspect the limit. The automated tests cover midstream limits,
   so there is no need to exhaust your subscription deliberately.

8. **Check revoked access and setup.** Disconnect Dictidy in ChatGPT settings, then try a rewrite.
   Expect an error or a request to reconnect, with no API billing fallback. Reconnect, then open
   **Settings → General → Run Setup Again** and verify the Rewrite step shows the same subscription
   controls. It must require an available selected model before continuing.

## Reporting a failure

Record the step, whether failure occurred before or after browser consent, and Dictidy's displayed
error code/request ID if provided. Do not share authorization URLs, callback URLs, Keychain contents,
access tokens, refresh tokens, or ID tokens. A connection can succeed while inference is unavailable
for a particular account or preview rollout; report that distinction.

OpenAI references: [registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
[models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
and [preview requirements](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations).
