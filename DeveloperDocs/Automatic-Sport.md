# Automatic Sport

Automatic Sport links workout activities to existing Trio override presets. Open **Settings → Devices → Smart Watch → Apple Watch → Automatic Sport**, use **+ Add Link**, and choose an activity and an override for each row. Each activity has one link; different activities may share a preset. The feature starts off and accepts only presets with a finite, positive duration.

If the override list is empty, open **Adjustments → Add Override**, configure the override, turn off **Enable Indefinitely**, choose a positive duration, and use **Save as Preset**. Starting a custom override does not save a selectable preset. Temporary target presets are a separate type and are not listed here. Return to Automatic Sport after saving the preset to reload the list.

Each link needs an Apple Shortcuts personal automation on the paired iPhone: **Apple Watch Workout → Start → matching workout type → Start Sport in Trio → the corresponding link**. Configure automatic execution in Shortcuts after checking behavior on your devices. The menu does not create or inspect personal automations. The link ID selects the current preset in Trio; changing a preset keeps the automation, while changing an activity invalidates its previous link and requires updating the automation. Deleting a link makes its old action fail without choosing a replacement.

The override ends at its preset duration. Workout end, pause, resume and post-workout recovery are not linked in this version. Do not connect the generic Cancel Override action to workout end: that action can cancel a manually chosen override.

Sport never replaces an active manual override or temporary target. Manual activation or editing takes priority. Duplicate starts do not extend an existing sport override; after manual cancellation or takeover, new starts are suppressed until the original sport duration has elapsed. A new workout in that interval may therefore require a manual override. There is no inference from heart rate, steps or saved HealthKit workouts, and no AI service is used.

## Implementation and validation

The configuration is stored in `TrioSettings`. The dedicated App Intent resolves a stable `SportOverrideRule` ID at execution time. `SportModeCoordinator` copies the selected preset to a separate activation with its own UUID. The optional `OverrideStored.sportRuleID` records provenance, using a versioned Core Data model and lightweight migration. Adjustment writes share a synchronous transaction gate so manual actions retire sport in the same save. APS checks sport's actual start and expiry independently of Home or Nightscout.

Existing override storage, chart, loop and upload paths are reused. No dosing formulas or preset therapy parameters are invented by this feature. Existing Nightscout uploads still apply when configured.

Local simulator verification is recorded in the implementation plan. Physical Apple Watch delivery remains unvalidated: Shortcuts does not provide a verified original workout timestamp/UUID to this implementation. It cannot reliably distinguish a delayed first invocation from a current workout. A received action is not proof of a currently running workout. Before distribution or use for unattended therapy, verify start delivery, locking, disconnection/reconnection, queued events and the exact workout filters on the intended devices. If obsolete starts can be delivered without detectable provenance, use confirmation or revisit the automatic trigger design.

Switching the feature off stops future automatic starts and leaves the current override under its normal expiry/manual controls. Keep the database when disabling. Reverting to an older build is not a database rollback: the newer model must be supported by any replacement build.
