import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSPanel?
    private let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sin icono en el Dock: es un widget de escritorio
        NSApp.setActivationPolicy(.accessory)

        let controller = WidgetViewController(monitor: monitor)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 328, height: 500),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = controller
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        panel.orderFront(nil)
        window = panel

        // Ajustar la ventana al tamaño real del contenido
        panel.setContentSize(controller.view.fittingSize)

        // Colocar en la esquina superior derecha de la pantalla donde está el cursor,
        // una vez la ventana ya tiene su tamaño final y pantalla asignada
        let screen = panel.screen
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        if let screen = screen {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            let x = min(max(visible.maxX - size.width - 24, visible.minX), visible.maxX - size.width)
            let y = min(max(visible.maxY - size.height - 24, visible.minY), visible.maxY - size.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        monitor.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// Punto de entrada
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
