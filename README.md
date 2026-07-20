# Quiet Worlds iOS Build Runner

This public repository contains infrastructure only. It has no application source, Unity project, generated Xcode project, game asset, signing material, APK, or IPA.

The sole manual workflow uses a standard GitHub-hosted `macos-15` runner. It downloads one private, hash-pinned Unity Xcode export; verifies the detached manifest and complete archive inventory before extraction; imports protected Ad Hoc signing inputs into an ephemeral keychain; compiles and signs one IPA; verifies its identity; returns the IPA and verification JSON directly to a bounded private HTTPS route; and destroys transient payload and signing state.

The workflow never publishes a GitHub Actions artifact and has no automatic trigger.
