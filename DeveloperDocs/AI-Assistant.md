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

The user interface has one **Enable AI Assistant** switch, plus the API key and model. Enabling it presents a short data-sharing explanation once. Accepting enables all seven categories as an access ceiling and always selects data automatically within seven days. The planner still selects only the categories and interval relevant to each question; it does not send all history on every turn. Diagnostic logs are selected only for technical questions and remain restricted to warnings/errors. Switching AI off blocks planning and answering while retaining saved chats.

Consent version 2 replaces the old per-category consent. Older archives stay readable, but their previous consent cannot authorize broader access: users must activate the assistant and accept the new explanation. Acceptance preserves the model and conversations, enables automatic selection, and disables remote continuity. Legacy configuration fields remain decodable and internal manual/preview paths remain testable, but the app exposes no category toggles, history picker, JSON preview, request byte count, severity filter or remote-storage switch.

Local conversations are authoritative. The unified flow uses `store: false` with at most six prior messages / 6,000 characters; old raw snapshots do not accumulate in a remote chain. API conversation storage does not connect Trio chats to ChatGPT's chat history or memory. No ChatGPT account synchronization is implemented. OpenAI's applicable API retention policies still apply. Requests never expose tools, and model output is displayed as text only.

API schema references: https://developers.openai.com/api/docs/guides/conversation-state and https://developers.openai.com/api/reference/resources/responses/methods/create . Instructions are sent on every turn, including chained turns.

Replies default to short, friendly explanations for a person unfamiliar with glucose management or Trio: roughly 60–100 words,
at most three relevant points, no tables or complete settings inventories unless requested. Broad settings reviews explain a few
observations and offer one non-treatment next step or focused question. Evidence and dosing restrictions still apply; the prompt
asks for only the limitations relevant to the answer and does not treat an override target difference as an error by itself.
`AIPrompt` reads the app's effective language from `Bundle.main.preferredLocalizations` (development language, then English as
fallback) and adds its language name and identifier to the instructions on every send. This follows Trio's language, including the
iOS per-app language selection, rather than guessing from the question, region, logs or earlier replies. No separate AI language
setting is stored. Brevity and response language are model instructions, not post-processing or a guarantee of generated wording.

Automatic selection first sends the question and a bounded recent conversation (no device snapshot) to the same configured
model using a strict Structured Outputs schema. The result chooses a relative start/end within the last 168 hours and a subset
of enabled categories. Local validation rejects invalid intervals, malformed plans and unauthorized categories before any data
fetch. An invalid plan continues to a normal chat answer without reading device data, with an explicit note that selection failed and actual data availability is unknown. It never broadens the selection or silently shares all data. A valid plan's answer request contains only the selected context.
The planning request adds latency and some tokens; the saving comes from omitting irrelevant records, not from a claim of zero
context cost. The internally recorded byte count totals planning and answer requests, including when selection is unavailable. Reference:
[OpenAI Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs).

Snapshots distinguish `generatedAt` from `intervalStart` / `intervalEnd`; a past interval does not end at the current time. A rolling
cutoff advancing between questions is not evidence of an earlier mistake. For inadequate coverage, the prompt asks for a brief
explanation and a useful next step. A seven-day limit does not imply seven days of records actually remain on the device.

Disk is the throwing persistence primitive already used by FileStorage. AI uses it directly so failed or corrupt conversation writes cannot be silently treated as success; no new database is introduced. Credentials are excluded from all Codable configuration and archive types.

## Using the assistant

Tapping the **Trio AI** badge at the top right of Home opens a short introduction with an **AI Settings** button. The introduction starts in a medium sheet and expands when settings open. Opening it does not enable AI or send a request.

All app-generated assistant copy is localized in all 22 Trio languages: English, Bulgarian, Czech, Danish, German, Spanish, French, Hebrew, Italian, Korean, Norwegian Bokmål, Dutch, Polish, Portuguese (Portugal), Romanian, Russian, Swedish, Turkish, Ukrainian, Vietnamese, Simplified Chinese and Traditional Chinese. This includes settings, consent, chat controls, default conversation titles, graph questions, accessibility labels, loading/cancellation messages and errors. Model identifiers and brand names remain unchanged. Provider errors use localized app messages instead of displaying arbitrary server text. Existing user messages and custom conversation titles are preserved. The app's effective language controls both this UI and the answer-language instruction.

The Home screen also has a speech-bubble shortcut at the lower right, beside the information/statistics panel and above the tab bar.
It opens the existing conversations screen in a sheet with its own navigation and a Close button. The shortcut has a dedicated
52-point touch target, keeps the dashboard's existing vertical layout, and is available before setup so users can reach AI Settings.
Opening the speech-bubble shortcut does not send a request or enable AI. The original Settings → Features → AI Assistant entry remains available.
The graph's info button presents a dedicated chat directly above Home and automatically asks for an explanation of its visible interval (tracked after pan/zoom without invalidating the Home layout). Its back arrow dismisses to Home, without showing the conversation list. The sheet carries the question in an identifiable presentation item so the initial question and sheet cannot become out of sync. Sending starts when the chat is visible and AI is enabled, consented and configured. If setup is needed, returning from AI Settings automatically resumes the pending question. Appearance changes do not repeat a sent request. The automatic graph question is passed directly to the sending path rather than put in the composer; it never replaces or clears a user draft, including during loading or failure. Failures do not automatically resend. The regular chat bubble still opens the conversation list. The original chart legend is available from the info button's context menu. The model receives
selected stored data, not an image of the chart; future chart portions are forecasts, not observations.

Open **Settings → Features → AI Assistant → AI Settings** (also searchable as “AI Assistant” or “OpenAI”). Enter the key in the secure **OpenAI API Key** field; finishing editing or leaving the screen saves it automatically. A saved key replaces the input with a masked preview showing only its first ten and last four characters (short values are fully masked). Tap the preview to enter a replacement; an empty replacement keeps the current key, and a failed write leaves the saved key and preview intact. The full saved value is never placed in a text field or archive. There are no Save, Replace, or Delete buttons. The default model is `gpt-4.1-mini`, defined in `AIPrompt`. The **AI Model** picker offers GPT-4.1 Mini, GPT-5.6 Luna, GPT-5.6 Terra, GPT-5.6 Sol, and GPT-6 Astra; choosing a preset saves it immediately. Choose **Custom Model** to enter another Responses-compatible model ID, which saves when editing ends or the screen closes. Existing custom IDs remain editable. This is a built-in list, not a live query of account permissions; model availability depends on the API project. Reference: https://developers.openai.com/api/docs/models .

Turn on **Enable AI Assistant** and accept the short explanation. There are no separate data controls: question-specific selection within seven days is automatic. New Chat creates a local conversation. Reopen it from Conversations; use its context menu to rename/delete, or swipe to delete locally. The composer supports multiple lines, cancellation and per-conversation in-memory drafts. When an assistant reply arrives, the composer loses focus so the keyboard closes and the reply is easier to read. Tapping the composer opens the keyboard again.

The API credential provider uses Trio's `Keychain` protocol and `BaseKeychain`, with synchronization disabled and `whenUnlockedThisDeviceOnly` accessibility. The key lives only in the Keychain entry `AIAssistant.OpenAI.apiKey`; AI settings and archives have no credential field. Existing Nightscout credentials and their SHA-1 representation are used only for exact-value redaction, never as context fields.

## Data and persistence

`DiskAIConversationStore` writes `Application Support/ai/assistant-v1.json` atomically through the existing `Disk` and `JSONCoding`. The versioned archive includes AI settings, conversation titles/UUIDs/messages/timestamps, last response IDs, and the most recent approximate request byte count. It is excluded from backup and protected until first user authentication after restart. Corrupt or unreadable archives surface an error and are not silently reset. A user question is sanitized and saved before the POST; a successful answer and response ID are then saved. A pending turn clears persisted remote-chain state so termination or cancellation falls back to local history.

The read-only adapter fetches committed records from private CoreDataStack contexts using predicates on `date`, `timestamp`, or `deliverAt`, newest first. Fetch limits apply in the database. It maps GlucoseStored, PumpEventStored/BolusStored/TempBasalStored, CarbEntryStored and OrefDetermination into explicit Codable value types. Settings/preferences/pump limits use an explicit allowlist; schedules include saved basal, carb ratios, ISF and targets. No treatment services or managed objects reach the AI service or module. No algorithm is run to produce data.

IOB/COB are included with the timestamp of their determination when that category is selected. Suggested SMBs remain distinct from actual pump events and enacted flags. Raw and stored smoothed glucose are identified separately. Current settings cannot establish which configuration existed at a historical timestamp.

For intervals over 24 hours, glucose, pump, carbohydrate and determination records are summarized into UTC-hour buckets covering
the entire requested interval (at most 169 partial/full buckets over seven days). Local fetches are bounded per 24-hour chunk:
2,000 glucose rows, 4,000 pump events, 500 carb entries and 2,000 determinations, with explicit truncation notes. The glucose fields
are sample count, first/last timestamps, min/max and sample mean; they are not time-weighted TIR. Pump summaries keep recorded
pump boluses, external insulin and unclassified amounts separate and never calculate basal delivery. Meal and FPU carbs stay
separate. Determination summaries retain counts, not full reasons. Detailed questions should select a shorter interval. Settings,
adjustments, stored TDD/boundary references and optional logs retain their existing bounds.

Limits for detailed snapshots (up to 24 hours):

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
| Recent local conversation | Automatic: 6 messages / 6,000 characters; manual: 20 / 24,000 |
| User question | 6,000 characters |
| Encoded request | 240,000 bytes |
| Response download | 1,000,000 bytes |
| Response output budget | Answer: 2,000 tokens; planning: 1,000 |

`FileAILogReader` opens SimpleLogReporter's `logs/log.txt` and `logs/log_prev.txt` read-only, scans bounded tails on a utility task, and parses the reporter's timestamp/category format. It filters interval, optional categories and WARN/ERR severity (severity filtering defaults on). It keeps complete newest matching lines within the byte budget. Partial final lines, continuation lines and oversized single lines are omitted. Files are not changed and logs are not cached. Context notes describe truncation and availability limits.

Redaction occurs on JSON value strings before encoding, on user/assistant text before persistence, and again on outgoing input strings. Sensitive dictionary keys, known keys/secrets, OpenAI keys, Authorization/Bearer/Basic/Digest, JWTs, cookies, password/token assignments and escaped credential fields are masked. Network URLs are removed completely, including user info, paths, query and fragment, because they are unnecessary to explain therapy. The outer sanitized context remains valid JSON. Arbitrary encodings or identifiers in free text cannot be guaranteed safe. The planner selects logs only for explicit technical questions, with warnings/errors filtering enabled by the unified consent flow.

The native ephemeral URLSession client posts only to `https://api.openai.com/v1/responses`, sets the key only in Authorization, disables cookies/cache, rejects redirects, caps download size, uses 90-second request / 120-second resource timeouts, propagates cancellation and does not automatically retry POSTs. It decodes Responses text/refusal blocks, rejects incomplete or empty output and reports sanitized API errors. No tool schema or generated action execution exists. Assistant output uses native selectable attributed text with inline Markdown emphasis and preserved whitespace; user messages remain literal. The renderer copies only emphasis/code attributes into fresh text, so generated link, image and custom attributes cannot become interactive or load content. It falls back to literal text if parsing fails. This display-only formatting also applies to saved replies; stored messages are unchanged. Reference: [Apple's Markdown attributed-string documentation](https://developer.apple.com/documentation/foundation/instantiating-attributed-strings-with-markdown-syntax).

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

Added under `Trio/Sources/Modules/AIAssistant/`: `AIAssistantProvider.swift`, `AIAssistantStateModel.swift`, `AIAssistantRootView.swift`, `AIChatView.swift`, `AISettingsView.swift`.

Added `Trio/Sources/Assemblies/AIAssembly.swift` for explicit Swinject composition and this document.

Modified only these existing integration files: `Trio/Sources/Application/TrioApp.swift`, `Trio/Sources/Router/Screen.swift`, `Trio/Sources/Modules/Settings/SettingItems.swift`, `Trio/Sources/Modules/Settings/View/Subviews/FeatureSettingsView.swift`, and `Trio.xcodeproj/project.pbxproj` for target membership. Submodules were initialized at their existing pinned commits; no dependency revision changed.

## Validation and limits

New Swift Testing suites in TrioTests: `AIAssistantTests.swift`, `AIContextTests.swift`, `AICredentialTests.swift`, `AIDataReaderTests.swift`, `AIOpenAIClientTests.swift`, `AIServiceTests.swift`, `AITransportTests.swift`. Tests use an in-memory Core Data stack, isolated temporary archives, a uniquely named Keychain service, fixture builders/clients and URLProtocol. They make no real OpenAI requests.

Covered behaviors: privacy defaults/gates; fresh context; date bounds and newest limits; rotated log filtering and unchanged files; key/token/header/cookie/escaped-value redaction in serialized requests; actual Keychain replace/delete; request encoding and response decoding; HTTP errors and cancellation; local history/reopen/rename/delete/response IDs; corrupt archive handling; opt-in remote continuity and chain invalidation; per-chat draft preservation; sanitized preview and send.

Initial unsigned test-host launch failed in existing Trio Keychain startup code. Local simulator testing therefore uses ad hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`), not a distribution identity. `CI=true` skips the repository-wide formatting script, preserving unrelated files. Build output is kept outside the repository in `/private/tmp/trio-ai-build`.

Remaining limitations: no on-device/live-API or clinical validation; no streaming UI, embeddings or remote deletion; no historical versioning of settings/schedules; linked override/temporary-target parameters can be unavailable; no TDD computation; no complete multiline log parsing; no guarantee of recognizing every free-text credential encoding. Local context can be incomplete, stale or truncated, and AI explanations are not proof of causality or a dosing recommendation. Default Responses storage is off, but this does not promise zero provider retention; see https://developers.openai.com/api/docs/guides/your-data .

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

## Automatic selection and chart explanation verification

On 2026-09-11, the simulator test build passed with 42 tests in seven AI suites. Coverage includes inline Markdown emphasis and
inert links/images, old configuration decoding, manual-mode persistence, automatic selection with no medical data in the planning
request, category and seven-day bounds, cancellation before collection, local automatic preview, structured schema/output-budget
transport, historical intervals, week-wide summaries, truncation notes, no duplicated records at chunk boundaries, separation of
pump/external insulin and meal/FPU carbs, and the graph viewport question. Responses were mocked; no live OpenAI requests were
made. On-device interaction and the quality of generated answers still require testing in the app.

Verification of simplified AI settings (2026-09-11): 36 tests in 5 suites passed on the iPhone 17 Pro / iOS 26.2 simulator (`AIServiceTests`, `AIAssistantTests`, `AIContextTests`, `AIOpenAIClientTests`, `AICredentialTests`). The two new regression tests first failed against the old consent flow, then passed: acceptance enables automatic all-category access without remote continuity, disabling blocks requests while preserving chats, and version-1 consent cannot authorize the new scope. Italian and Polish copy is included for the new controls and consent. Fixed existing missing parentheses around `(any Error).self` in tests to restore compilation. API responses were simulated; no live API call, manual UI verification or new distribution build was performed.

Graph entry verification (2026-09-11): app and tests compiled successfully; 22 tests in `AIServiceTests` and `AIAssistantTests` passed. The new regression covers automatic initial sending, deferred sending after setup, and avoiding duplicate requests on repeated appearances. The first simulator launch failed with Mach error -308 before tests ran; `test-without-building` succeeded on retry. API responses were simulated. The Home dismissal route was reviewed in code; manual device navigation and a distribution build were not performed.

Empty history is a normal chat case: the answer prompt explains missing records briefly, offers general app help, and never treats missing readings as zero glucose or zero insulin. Missing records only describe the selected interval, not the entire database. Invalid planning output is a separate condition: no local reads are performed and the answer is told that data availability is unknown. Authentication, transport, storage and cancellation failures retain their normal error handling.

Empty-history verification (2026-09-11): 24 tests in `AIServiceTests` and `AIContextTests` passed on iPhone 17 Pro / iOS 26.2, with a successful test build. Cases cover empty six-hour and seven-day histories, malformed/reversed/out-of-bounds/unauthorized plans continuing without device reads, request-size accounting, and existing cancellation/privacy boundaries. The four invalid-plan cases first reproduced `invalidContextPlan` before the fix. Responses were simulated; live model wording and device UI were not tested.

Graph composer verification (2026-09-11): 15 service tests passed with simulated API responses. The graph regression verifies that the automatic question is sent separately from the composer and a user draft survives during and after that request; existing setup deferral, duplicate prevention and manual draft-retention tests still pass. No device UI or live API test was performed.

Localization and badge verification (2026-09-11): the app compiled and 29 tests in `AIAssistantTests`, `AIServiceTests` and `AITransportTests` passed on iPhone 17 Pro / iOS 26.2 with `-testLanguage it -testRegion IT`. The catalog check covers 70 assistant strings in all 22 languages, preserving interpolation placeholders; runtime tests load all 21 translated bundles, check localized default titles/errors, and verify HTTP errors do not expose server text. The badge-to-introduction-to-settings route was reviewed in code. No manual device UI, native-speaker review or distribution build was performed.
