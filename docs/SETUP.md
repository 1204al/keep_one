# Run KeepOne on your iPhone

You need a Mac with Xcode 27 and the iOS SDK installed, an Apple Account, and an iPhone
running iOS 18 or later. Connect the phone with a USB cable or use an existing Wi-Fi pairing.

## Build and install

1. Open `KeepOne.xcodeproj` in Xcode.
2. Go to **Xcode → Settings → Apple Accounts** and sign in. A free Personal Team is enough.
3. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set
   your Apple development team ID and a unique bundle ID there. Xcode reads this file for
   automatic signing. It is ignored by Git so your personal signing settings stay local.
4. On the iPhone, turn on **Settings → Privacy & Security → Developer Mode** and restart
   if asked. Unlock the phone and accept **Trust This Computer** if prompted.
5. Choose the iPhone as the run destination and press **⌘R**. The KeepOne scheme uses
   Release mode for faster photo analysis.
6. If iOS asks you to trust the developer, open **Settings → General → VPN & Device Management**
   on the phone and trust your developer certificate.

If Xcode reports **No Accounts** or **No profiles**, finish signing in, check the selected
team and let automatic signing create a fresh provisioning profile.

## First scan

Open KeepOne, complete onboarding and allow **Full Access** to scan the whole library.
Keep the app open during the first scan; you can start reviewing as categories appear.
Later scans check only new or edited items.

Suggestions enter the Trash Queue only when you choose them. Review that queue and confirm
before anything is moved to Recently Deleted in Photos.

## When the development build expires

Free Personal Team builds expire after seven days. Connect the iPhone and run the project
again with **⌘R** to refresh the signature.

Installing over the existing app preserves the analysis cache, Trash Queue, protections
and learned preferences. Before deleting the app, export your preferences from
**Settings → AI → Learned preferences → Export**.

## Project and model

The Xcode project is included. If you use XcodeGen, regenerate it with `xcodegen generate`
from the repository root; its configuration is in `project.yml`.

The semantic model and concept embeddings are already bundled. Model preparation,
regeneration and license details are in [MODELS.md](MODELS.md). Without the model,
semantic categories are disabled; the other cleanup features still work.
