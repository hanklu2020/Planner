# Planner MVP 0.0.1
Native SwiftUI iPhone app. Add tasks, toggle completion, add journal text and contact names, swipe to delete. Data is stored locally in UserDefaults via AppStorage. No network or special entitlements. iOS 17+ deployment target.

## Build
Upload this directory's contents (including `.github`) to a public GitHub repository. Open Actions > Build Planner IPA > Run workflow. Download Planner-IPA artifact, unzip it, and transfer Planner.ipa to iPhone Files. Open AltStore Classic > My Apps > + > Planner.ipa. Keep AltServer running and connected. The IPA is unsigned until AltStore signs it.

The source package has not been compiled or device-tested in the Linux environment used to create it. No Apple ID secrets belong in this repository. This MVP is not the final Planner database or archive implementation. Deleting the installed app deletes its local records; deleting the downloaded IPA does not uninstall the app.
