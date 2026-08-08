import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(
      scene,
      willConnectTo: session,
      options: connectionOptions
    )
    for context in connectionOptions.urlContexts {
      NotenFileInbox.shared.enqueue(context.url)
    }
  }

  override func scene(
    _ scene: UIScene,
    openURLContexts URLContexts: Set<UIOpenURLContext>
  ) {
    var hasUnhandledURL = false
    for context in URLContexts {
      if !NotenFileInbox.shared.enqueue(context.url) {
        hasUnhandledURL = true
      }
    }
    if hasUnhandledURL {
      super.scene(scene, openURLContexts: URLContexts)
    }
  }
}
