# Configure a model from launch parameters

Debug builds accept a runtime OpenAI-compatible endpoint and model ID. The app stores the selection for later manual launches; no LAN address or model ID is built into the app.

```sh
xcrun devicectl device process launch --device <DEVICE_ID> --terminate-existing <BUNDLE_ID> -- \
  -llm-base-url 'https://<API_HOST>/v1' -llm-model '<VISION_MODEL_ID>' -setup brain -test-model
```

Both `-llm-base-url` and `-llm-model` are required, once each. The endpoint must use HTTP or HTTPS and have a host; embedded credentials, query strings, and fragments are rejected. An invalid import leaves saved settings unchanged and skips the requested startup test or run.

The optional `-llm-extra-body` accepts one JSON object of provider-specific request options and saves it with the selection. If omitted, the extra body is `{}`. Repeated flags, missing values, invalid JSON, arrays and scalar values are rejected before any settings or credentials change. Passing this flag alone without the endpoint and model is also rejected.

For a provider that supports `chat_template_kwargs.enable_thinking`, disable thinking explicitly at runtime:

```sh
xcrun devicectl device process launch --device <DEVICE_ID> --terminate-existing <BUNDLE_ID> -- \
  -llm-base-url 'https://<API_HOST>/v1' -llm-model '<VISION_MODEL_ID>' \
  -llm-extra-body '{"chat_template_kwargs":{"enable_thinking":false}}' -test-model
```

This is an optional provider setting, not an app-wide default. Use only options supported by the selected server. Importing selects **Others**, clears the previous API key and role-specific model overrides, and resets token-parameter selection to automatic before saving the supplied endpoint, model and extra body. A server that requires authentication can receive an optional `IA_LLM_API_KEY` process environment variable through the development launcher. The app saves that key in the Keychain; the importer never accepts a key argument or logs arguments or the extra body. Omit the environment variable to configure a server without authentication; an old cloud key is never carried over, even when the host is unchanged.

These import flags are compiled only in Debug builds. They do not add a configuration URL that a web page can invoke. Existing App Store AI-service and analytics consent settings are unchanged.

Keep the phone and server on a reachable local network. Allow iOS Local Network access when prompted, then retry the model test if its first request failed while permission was pending. The app declares local networking support without disabling App Transport Security globally. Use the model test's sample image to verify image support; listing a model does not establish that it can read screenshots.

Debug builds also accept `-delete-intent <SAVED_INTENT_UUID>` to remove exactly one saved intent through the app's own store, preserving other intents and settings. Repeating it after deletion is a no-op; a malformed or repeated flag is rejected. This command has no URL equivalent.

```sh
xcrun devicectl device process launch --device <DEVICE_ID> --terminate-existing <BUNDLE_ID> -- \
  -delete-intent '<SAVED_INTENT_UUID>'
```
