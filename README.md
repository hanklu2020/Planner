# Planner 2.0

Native SwiftUI iPhone app, iOS 17+, with four fixed tabs: **目標｜計畫｜日記｜人脈**. Works offline without an account or server. The bundle identifier remains `com.personalplanner.mvp` for continuity with the original app.

## Included

- Six goal domains in the agreed layout: 靈性 / 社交, 體能 / 智能, 家庭 / 工作.
- Goals with achievement criteria, optional target date, editable status, tasks, steps, next action, and review history. Completing all tasks offers review; it never automatically claims goal achievement.
- Independent/goal-linked tasks, notes, step checklists and reordering, deadlines, cancellation/reopening, linked contacts, and up to three priorities per day through a task's context menu.
- Day/week/month/year planning, date-title menu, pinch to change scale, calendar overviews, domain/goal/search filters, unplanned/attention queues, completed/cancelled disclosure groups.
- Inline date shortcuts, bulk scheduling, sequential scheduling with skip/undo and visible daily load, schedule history. Week/month/year assignments remain unspecific, and never become arbitrary day assignments. Rescheduling does not change deadlines.
- Journal writing/editing/deleting, optional content-language marker, completed-task history, oldest-to-newest timeline, two-day recent buffer, loading older records in batches. Interface language is Traditional Chinese.
- Contact details, manual interactions, pending related tasks, completed interactions, archiving, protected long-term history, explicit cleanup of old manual interactions.
- Atomic versioned JSON storage, previous-save recovery, JSON export/import, strict backup validation, automatic migration from the MVP's `tasks`, `journal`, and `contacts` UserDefaults keys. Legacy keys are retained.

## Behavior decisions

1. Missed plans stay under 待處理; they do not automatically roll into tomorrow. Only missed hard deadlines are overdue.
2. Completion history refers to the original task. Today/yesterday are 最近完成; older records are 完成紀錄. There is no destructive move or duplicate task.
3. Years/months/weeks are time views, not extra goal levels.
4. Steps are not separately scheduled. Split an independently schedulable action into another task.
5. Goal task counts exclude cancelled tasks, and are not outcome percentages.

The MVP did not record dates. Migrated records use the import day, explicitly annotated on completed legacy tasks and journal entries. Original dates cannot be recovered.

## Build and install

1. Open **Actions → Build Planner IPA → Run workflow** and select the branch containing this version. The feature branch builds automatically on push.
2. The workflow generates the Xcode project, runs unit and iPhone simulator UI tests, then builds an unsigned Release IPA.
3. Download **Planner-IPA** from a successful run, unzip it and save `Planner.ipa` to iPhone Files.
4. In **AltStore Classic → My Apps → +**, select the IPA and install with the same Apple ID/app identity as before. Do not uninstall first if you want to retain local data. Export a backup before replacing an existing installation when available.

`Planner-Test-Results` contains Xcode test results and UI screenshots. The unsigned IPA requires signing through AltStore before it can launch on a physical iPhone. No Apple credentials belong in the repository.

## Development

```sh
brew install xcodegen
xcodegen generate
open Planner.xcodeproj
```

Sources are separated into Foundation models/persistence, a transactional shared store, and SwiftUI views. XcodeGen generates app and test targets from `project.yml`. Linux cannot run Xcode; compilation and simulator checks run on the macOS Actions runner. Physical-device gesture, keyboard and AltStore update behavior require a device check.

Data stays on the device. Export a complete backup through **目標 → 設定與備份** before deleting the app or moving devices. Full English interface localization, recurrence, automatic reminders, cross-device sync and a server are not included in this release.
