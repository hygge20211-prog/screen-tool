import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private var coordinator: MainCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let mainWindow = UIWindow(windowScene: windowScene)
        self.window = mainWindow

        let gallery = GalleryViewController()
        let nav = UINavigationController(rootViewController: gallery)
        nav.navigationBar.prefersLargeTitles = true
        mainWindow.rootViewController = nav
        mainWindow.makeKeyAndVisible()

        let coordinator = MainCoordinator()
        coordinator.start(in: windowScene, mainWindow: mainWindow)
        self.coordinator = coordinator
    }
}
