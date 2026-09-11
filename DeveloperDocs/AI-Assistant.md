# Experimental AI Assistant

## Implementation plan and boundaries

The feature is implemented only in this local fork. No algorithm or treatment behavior changes.

- Add Foundation DTOs, privacy settings, redaction and conversation persistence; test secrets and local history first.
- Add a read-only Core Data adapter, context builder and bounded reader of SimpleLogReporter's existing files; test dates, limits and disabled categories.
- Add a native URLSession Responses client and orchestration; test encoding, decoding, errors, consent, cancellation and fresh context without live requests.
- Add an Observation state model and native SwiftUI screens; integrate through Screen and Feature Settings, then build and run relevant TrioTests.

Existing architecture inspected: StorageAssembly, SettingsManager, FileStorage/Disk/Keychain, Logger/SimpleLogReporter, Treatments and History providers/state/views, Settings navigation, BaseStateModel/BaseProvider, NightscoutAPI/NetworkService, all five requested storage protocols and implementations, CoreDataStack and Swift Testing storage suites.

`BaseStateModel` and `BaseProvider` inject mutable therapy services. The AI module deliberately uses a plain Provider and an Observation state model with explicit AI-only dependencies. Only the composition adapter knows Trio settings and Core Data. All data leaving it are value DTOs; no managed objects or mutable therapy protocols reach AIService or the UI.

Existing history methods are algorithm/upload oriented: glucose accepts hours, pump/carbs fix 24 hours, determination fetch limits to one, and TDDStorage exposes computation and writes. The adapter instead reuses CoreDataStack background contexts and bounded date-predicate fetches. It never computes TDD or invokes an algorithm. Settings are current snapshots, not historical configuration; determination timestamps and enacted flags retain that distinction.

Graph: Screen → AIAssistant views/state → AIService → AIContextBuilder → AITrioDataReading adapter. AIService → AIContextRedactor → OpenAIClient → HTTPS. AIService → AIConversationStore → Trio Disk. Credential provider → existing Keychain abstraction. No AI tools, actions, pump manager, bolus API or settings setter.

## Privacy and continuity

AI and all context categories default off, history defaults to six hours. Explicit enablement and consent are required before each request can pass the service gate. Context is rebuilt and sanitized on every send. Context preview is local and sanitized.

Local conversations are authoritative. Default requests use `store: false` and bounded local message history. Optional remote continuity uses `store: true` / `previous_response_id`; changing privacy selections or model invalidates the remote chain. Remote storage is separate from local deletion. Requests never expose tools, and model output is displayed as text only.

API schema references: https://developers.openai.com/api/docs/guides/conversation-state and https://developers.openai.com/api/reference/resources/responses/methods/create . Instructions are sent on every turn, including chained turns.

Replies default to short, friendly explanations for a person unfamiliar with glucose management or Trio: roughly 60–100 words,
at most three relevant points, no tables or complete settings inventories unless requested. Broad settings reviews explain a few
observations and offer one non-treatment next step or focused question. Evidence and dosing restrictions still apply; the prompt
asks for only the limitations relevant to the answer and does not treat an override target difference as an error by itself.
`AIPrompt` reads the app's effective language from `Bundle.main.preferredLocalizations` (development language, then English as
fallback) and adds its language name and identifier to the instructions on every send. This follows Trio's language, including the
iOS per-app language selection, rather than guessing from the question, region, logs or earlier replies. No separate AI language
setting is stored. Brevity and response language are model instructions, not post-processing or a guarantee of generated wording.

Disk is the throwing persistence primitive already used by FileStorage. AI uses it directly so failed or corrupt conversation writes cannot be silently treated as success; no new database is introduced. Credentials are excluded from all Codable configuration and archive types.

## Using the assistant

The Home screen also has a speech-bubble shortcut at the lower right, beside the information/statistics panel and above the tab bar.
It opens the existing conversations screen in a sheet with its own navigation and a Close button. The shortcut has a dedicated
52-point touch target, keeps the dashboard's existing vertical layout, and is available before setup so users can reach AI Settings.
Opening it does not send a request or enable AI. The original Settings → Features → AI Assistant entry remains available.

Open **Settings → Features → AI Assistant → AI Settings** (also searchable as “AI Assistant” or “OpenAI”). Enter the key in the secure **OpenAI API Key** field; finishing editing or leaving the screen saves it automatically. A saved key replaces the input with a masked preview showing only its first ten and last four characters (short values are fully masked). Tap the preview to enter a replacement; an empty replacement keeps the current key, and a failed write leaves the saved key and preview intact. The full saved value is never placed in a text field or archive. There are no Save, Replace, or Delete buttons. The default model is `gpt-4.1-mini`, defined in `AIPrompt`. The **Model** picker offers GPT-4.1 Mini, GPT-5.6 Luna, GPT-5.6 Terra, GPT-5.6 Sol, and GPT-6 Astra; choosing a preset saves it immediately. Choose **Custom Model** to enter another Responses-compatible model ID, which saves when editing ends or the screen closes. Existing custom IDs remain editable. This is a built-in list, not a live query of account permissions; model availability depends on the API project. Reference: https://developers.openai.com/api/docs/models .

Review **Data Sharing**, tap **I Agree**, enable the assistant and choose the data categories. All categories initially remain off; the window defaults to 6 hours, with 1/3/6/12/24 hours available. Preview AI Context does not send a request and can be used before enabling the feature. New Chat creates a local conversation. Reopen it from Conversations; use its context menu to rename/delete, or swipe to delete locally. The composer supports multiple lines, cancellation and per-conversation in-memory drafts. **Select Therapy Context** selects settings, glucose, recorded insulin, carbs, determinations, overrides and temporary targets in one action; it does not enable the assistant or accept consent. Logs remain optional.

The API credential provider uses Trio's `Keychain` protocol and `BaseKeychain`, with synchronization disabled and `whenUnlockedThisDeviceOnly` accessibility. The key lives only in the Keychain entry `AIAssistant.OpenAI.apiKey`; AI settings and archives have no credential field. Existing Nightscout credentials and their SHA-1 representation are used only for exact-value redaction, never as context fields.

## Data and persistence

`DiskAIConversationStore` writes `Application Support/ai/assistant-v1.json` atomically through the existing `Disk` and `JSONCoding`. The versioned archive includes AI settings, conversation titles/UUIDs/messages/timestamps, last response IDs, and the most recent approximate request byte count. It is excluded from backup and protected until first user authentication after restart. Corrupt or unreadable archives surface an error and are not silently reset. A user question is sanitized and saved before the POST; a successful answer and response ID are then saved. A pending turn clears persisted remote-chain state so termination or cancellation falls back to local history.

The read-only adapter fetches committed records from private CoreDataStack contexts using predicates on `date`, `timestamp`, or `deliverAt`, newest first. Fetch limits apply in the database. It maps GlucoseStored, PumpEventStored/BolusStored/TempBasalStored, CarbEntryStored and OrefDetermination into explicit Codable value types. Settings/preferences/pump limits use an explicit allowlist; schedules include saved basal, carb ratios, ISF and targets. No treatment services or managed objects reach the AI service or module. No algorithm is run to produce data.

IOB/COB are included with the timestamp of their determination when that category is selected. Suggested SMBs remain distinct from actual pump events and enacted flags. Raw and stored smoothed glucose are identified separately. Current settings cannot establish which configuration existed at a historical timestamp.

Limits per fresh snapshot:

| Data | Maximum |
|---|---:|
| Glucose readings | 300 |
| Pump/insulin events | 300 |
| Carb entries | 100 |
| Determinations | 100 |
| Overlapping overrides / temporary targets | 50 |
| Pre-window pump state records | 2 |
| Latest stored TDD snapshot in window | 1 |
| Each settings schedule | 96 |
| Selected log message bytes | 16,000 |
| Scanned tail per log file | 512,000 bytes |
| Recent local conversation | 20 messages / 24,000 characters |
| User question | 6,000 characters |
| Encoded request | 240,000 bytes |
| Response download | 1,000,000 bytes |
| Response output budget | 2,000 tokens |

`FileAILogReader` opens SimpleLogReporter's `logs/log.txt` and `logs/log_prev.txt` read-only, scans bounded tails on a utility task, and parses the reporter's timestamp/category format. It filters interval, optional categories and WARN/ERR severity (severity filtering defaults on). It keeps complete newest matching lines within the byte budget. Partial final lines, continuation lines and oversized single lines are omitted. Files are not changed and logs are not cached. Context notes describe truncation and availability limits.

Redaction occurs on JSON value strings before encoding, on user/assistant text before persistence, and again on outgoing input strings. Sensitive dictionary keys, known keys/secrets, OpenAI keys, Authorization/Bearer/Basic/Digest, JWTs, cookies, password/token assignments and escaped credential fields are masked. Network URLs are removed completely, including user info, paths, query and fragment, because they are unnecessary to explain therapy. The outer sanitized context remains valid JSON. Arbitrary encodings or identifiers in free text cannot be guaranteed safe: inspect the preview and leave logs off unless needed.

The native ephemeral URLSession client posts only to `https://api.openai.com/v1/responses`, sets the key only in Authorization, disables cookies/cache, rejects redirects, caps download size, uses 90-second request / 120-second resource timeouts, propagates cancellation and does not automatically retry POSTs. It decodes Responses text/refusal blocks, rejects incomplete or empty output and reports sanitized API errors. No tool schema or generated action execution exists. Output is rendered as plain selectable text with no generated links, images or HTML.

## File map

Added under `Trio/Sources/Services/AI/`:

- `AIModels.swift`: explicit context/conversation/configuration DTOs, limits and safe errors.
- `AIPrompt.swift`: single model default, instructions and consent copy.
- `AIContextRedactor.swift`: structural and text redaction.
- `AIConversationStore.swift`: throwing atomic archive persistence.
- `AICredentialProvider.swift`: replaceable credential interface and Keychain implementation.
- `AIContextBuilder.swift`: read-only data protocol, fresh context and category/window/size controls.
- `TrioAIDataReader.swift`: bounded Core Data to DTO adapter.
- `AISettingsSnapshot.swift`: explicit settings/preference allowlist.
- `AILogReader.swift`: existing-log tail reader and filters.
- `OpenAIClient.swift`: Responses DTOs and native HTTP implementation.
- `AIService.swift`: consent gates, conversations, sanitized context and request orchestration.

Added under `Trio/Sources/Modules/AIAssistant/`: `AIAssistantProvider.swift`, `AIAssistantStateModel.swift`, `AIAssistantRootView.swift`, `AIChatView.swift`, `AISettingsView.swift` (including context preview).

Added `Trio/Sources/Assemblies/AIAssembly.swift` for explicit Swinject composition and this document.

Modified only these existing integration files: `Trio/Sources/Application/TrioApp.swift`, `Trio/Sources/Router/Screen.swift`, `Trio/Sources/Modules/Settings/SettingItems.swift`, `Trio/Sources/Modules/Settings/View/Subviews/FeatureSettingsView.swift`, and `Trio.xcodeproj/project.pbxproj` for target membership. Submodules were initialized at their existing pinned commits; no dependency revision changed.

## Validation and limits

New Swift Testing suites in TrioTests: `AIAssistantTests.swift`, `AIContextTests.swift`, `AICredentialTests.swift`, `AIDataReaderTests.swift`, `AIOpenAIClientTests.swift`, `AIServiceTests.swift`, `AITransportTests.swift`. Tests use an in-memory Core Data stack, isolated temporary archives, a uniquely named Keychain service, fixture builders/clients and URLProtocol. They make no real OpenAI requests.

Covered behaviors: privacy defaults/gates; fresh context; date bounds and newest limits; rotated log filtering and unchanged files; key/token/header/cookie/escaped-value redaction in serialized requests; actual Keychain replace/delete; request encoding and response decoding; HTTP errors and cancellation; local history/reopen/rename/delete/response IDs; corrupt archive handling; opt-in remote continuity and chain invalidation; per-chat draft preservation; sanitized preview and send.

Initial unsigned test-host launch failed in existing Trio Keychain startup code. Local simulator testing therefore uses ad hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`), not a distribution identity. `CI=true` skips the repository-wide formatting script, preserving unrelated files. Build output is kept outside the repository in `/private/tmp/trio-ai-build`.

Remaining limitations: no on-device/live-API or clinical validation; no streaming UI, embeddings or remote deletion; no historical versioning of settings/schedules; linked override/temporary-target parameters can be unavailable; no TDD computation; no complete multiline log parsing; no guarantee of recognizing every free-text credential encoding. Local context can be incomplete, stale or truncated, and AI explanations are not proof of causality or a dosing recommendation. UI strings use SwiftUI localization conventions; translated AI copy has not been added to existing catalogs. Default Responses storage is off, but this does not promise zero provider retention; see https://developers.openai.com/api/docs/guides/your-data .

Final verification on 2026-09-11: Trio test build succeeded on Xcode 26.3 / iPhone 17 Pro simulator (iOS 26.2). **30 tests in 8 suites passed: 24 new AI tests and 6 existing SettingsSearchTests.** No new AI compiler warnings were reported; existing project/dependency warnings include extension version mismatch, duplicate source entries and Swift 6 concurrency migration warnings. Full original test suite and manual UI/device/live-API testing were not run.

Reproduce the selected suites with a local simulator destination (all HTTP in AI tests is intercepted):

```sh
CI=true xcodebuild -workspace Trio.xcworkspace -scheme 'Trio Tests' \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -derivedDataPath /private/tmp/trio-ai-build \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -parallel-testing-enabled NO \
  -only-testing:TrioTests/AIAssistantTests \
  -only-testing:TrioTests/AIContextTests \
  -only-testing:TrioTests/AICredentialTests \
  -only-testing:TrioTests/AIDataReaderTests \
  -only-testing:TrioTests/AIOpenAIClientTests \
  -only-testing:TrioTests/AIServiceTests \
  -only-testing:TrioTests/AITransportTests \
  -only-testing:TrioTests/SettingsSearchTests test
```


## Expanded therapy context

For the independent Trio AI app/source identifier, see [Fork versioning](Fork-Versioning.md).

Therapy context includes the bolus calculator fraction (`overrideFactor`), fatty/sweet meal toggles and factors, macro entry limits and carbohydrate alert threshold, in addition to all previously selected OpenAPS preferences and saved therapy schedules.

The optional **Overrides and Temporary Targets** category reads recorded runs overlapping the window and currently enabled configurations, including adjustments that began before the cutoff. DTOs distinguish recorded end times from planned end times and expose target, percentage, ISF/CR flags, SMB disable schedule and SMB/UAM limits where retained. Parameters on historical runs come from their linked stored configuration; they are not a new immutable audit trail.

Selecting insulin/pump history also includes the latest **already stored** TDD snapshot within the window and up to two earlier pump-state references: the latest suspension/resumption and the last temp basal program if its scheduled duration overlaps the cutoff. These references are labeled separately from in-window doses. No dosing/TDD algorithm is invoked.

Pump history retains SMB/manual bolus flags, external insulin, temp basal programs, suspensions and resumptions. Bolus amounts are the latest recorded values, including partial-dose corrections when stored. The database does not preserve all finalization/delivery flags. Temp basal rate × scheduled duration is not proof of delivered units; a subsequent program or suspension may interrupt delivery. TDD is a timestamped daily estimate and must not be summed with event doses or presented as the total for the selected interval. Glucose history continues to include both raw and stored smoothed readings and timestamps.

Expanded-context verification on 2026-09-11: **33 tests in 8 suites passed** (27 AI + 6 SettingsSearchTests), with a successful simulator build. Added regressions cover the missing bolus/meal parameters (first confirmed failing), therapy-category selection without implicit consent/enablement, overlapping adjustment history, stored TDD, and pump state crossing the selected cutoff. No physical-device or real OpenAI requests were used.
