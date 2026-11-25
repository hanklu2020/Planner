# Planner 0.1.0

Native SwiftUI iPhone app, iOS 17+. Compact inline toolbars, native three-tab navigation, and local records. No third-party app dependencies, network calls, or special entitlements.

## Interface

- **計畫:** pinch closed to move day → week → month → year; pinch open to reverse. Each completed pinch changes one level. The date/month beneath the starting anchor is retained when available; otherwise the selected date is retained. A small dead zone prevents accidental switches.
- Tap the date in the top toolbar for a calendar, the four time scales, or return to today. The alternative works without two-finger gestures. There are no swipe-to-change-period gestures.
- Day: up to three unfinished priority tasks, ordinary tasks, collapsed completed tasks.
- Week: weekly goals and seven vertical day groups. Tap a day to open it.
- Month: monthly goals, Monday-first calendar with pending task counts, and tasks for the selected day.
- Year: annual goals and twelve compact month rows. Tap a month to open it.
- **日記:** dated entries and live completed-task references, newest at the bottom. Tap an entry to edit; expand completed items as needed.
- **人脈:** searchable contacts, related pending tasks, manual interactions, and links to completed tasks. Open the contact's menu to add a task/interaction or edit the contact.
- The top + opens a focused editor. Extra fields stay collapsed. Editors require an explicit Save or Cancel so a swipe cannot discard text.

## Current scope

Basic add/edit/delete, completion, Top 3 validation, task/contact links, and existing on-device UserDefaults persistence are included to make the interface usable. Completed tasks appear as live references, not copied archive entries. Automatic two-day journal archival, carry-forward, Raspberry Pi backup/sync, advanced history cleanup, global search, and goal hierarchies are **not implemented** in this interface pass. No placeholder backup controls are shown.

## Existing data

The bundle identifier stays com.personalplanner.mvp. The tasks, journal, and contacts keys are unchanged. Original id/text/done records decode with defaults for new fields and retain their IDs/text. Original records have no dates, so they are assigned the current date on first decode; that date becomes persistent when that collection is next saved. Original completed tasks use that assigned date as their completion date because the historical date is unavailable. Loading alone does not rewrite the original bytes. Unreadable collections are protected against writes.

Install updates with the same signing identity and bundle identifier to retain the app container; do not uninstall first. Deleting the app deletes its local data. This is not a backup solution.

## Build and checks

The Build Planner IPA workflow supports manual runs and pull requests targeting main. It runs Foundation model checks and macOS store checks, generates the Xcode project with XcodeGen, compiles an unsigned iPhone app, validates the IPA ZIP, and uploads Planner-IPA.

On GitHub: Actions → Build Planner IPA → Run workflow → select the desired branch. Download Planner-IPA, unzip, and install Planner.ipa through AltStore using the existing signing setup.

The model checks cover pinch thresholds, calendar boundaries/leap years, legacy decoding, completion timestamps, and priority rules. Store checks cover persistence, original data identity, the priority limit, and unreadable-data protection. Pinch/scroll coexistence, keyboard behavior, VoiceOver, large text, and visual layout still require an iPhone or simulator review. No Apple ID secrets belong in this repository.
