// Test script to inject floating windows CSS and test functionality
(function() {
    // Add the floating windows CSS
    var css = `
        .red-ui-floating-window{position:absolute;background:var(--red-ui-primary-background);border:2px solid var(--red-ui-primary-border-color);border-radius:8px;box-shadow:0 4px 12px rgba(0,0,0,0.15);z-index:1000;min-width:200px;min-height:150px;overflow:hidden}
        .red-ui-floating-window.active{border-color:#d94f00;z-index:1001}
        .red-ui-floating-window-header{background:var(--red-ui-primary-background);border-bottom:1px solid var(--red-ui-primary-border-color);height:32px;cursor:move;display:flex;align-items:center;justify-content:space-between;padding:0 12px;user-select:none}
        .red-ui-floating-window-title{font-weight:bold;color:var(--red-ui-primary-text-color);font-size:13px}
        .red-ui-floating-window-controls{display:flex;gap:4px}
        .red-ui-floating-window-controls button{background:none;border:none;width:20px;height:20px;cursor:pointer;border-radius:3px;color:var(--red-ui-secondary-text-color);font-size:12px;display:flex;align-items:center;justify-content:center}
        .red-ui-floating-window-controls button:hover{background:var(--red-ui-secondary-background);color:var(--red-ui-primary-text-color)}
        .red-ui-floating-window-content{position:absolute;top:32px;left:0;right:0;bottom:0;overflow:hidden}
        .red-ui-floating-window::before{content:'';position:absolute;bottom:-2px;right:-2px;width:12px;height:12px;cursor:se-resize;background:transparent;z-index:2}
        .red-ui-floating-window::after{content:'⋰';position:absolute;bottom:2px;right:4px;font-size:10px;color:var(--red-ui-secondary-text-color);pointer-events:none;z-index:1}
        .red-ui-floating-palette{width:200px;height:calc(100vh - 120px)}
        .red-ui-floating-palette .red-ui-floating-window-content{display:flex;flex-direction:column}
        .red-ui-floating-palette .red-ui-palette-search{flex-shrink:0}
        .red-ui-floating-palette .red-ui-palette-scroll{flex:1;position:relative;top:0;bottom:0}
        .red-ui-floating-sidebar{width:320px;height:calc(100vh - 120px)}
        .red-ui-floating-sidebar .red-ui-floating-window-content{display:flex;flex-direction:column}
        .red-ui-floating-sidebar .red-ui-tabs{flex-shrink:0}
        .red-ui-floating-sidebar #red-ui-sidebar-content{flex:1;position:relative;top:0;bottom:0}
        .red-ui-floating-debug{width:350px;height:calc(100vh - 120px)}
        .red-ui-floating-debug .red-ui-floating-window-content{display:flex;flex-direction:column}
        .red-ui-floating-debug .red-ui-sidebar-header{flex-shrink:0}
        .red-ui-floating-debug .debug-content{flex:1;overflow-y:auto}
        .red-ui-floating-mode #red-ui-palette{display:none !important}
        .red-ui-floating-mode #red-ui-sidebar{display:none !important}
        .red-ui-floating-mode #red-ui-sidebar-separator{display:none !important}
        .red-ui-floating-mode #red-ui-workspace{left:0 !important;right:0 !important}
        .red-ui-floating-window.minimized{height:32px !important}
        .red-ui-floating-window.minimized .red-ui-floating-window-content{display:none}
        .red-ui-floating-window.minimized::before,.red-ui-floating-window.minimized::after{display:none}
    `;
    
    var style = document.createElement('style');
    style.type = 'text/css';
    style.innerHTML = css;
    document.head.appendChild(style);
    
    console.log('Floating windows CSS injected');
    
    // Test if RED.floatingWindows exists
    if (typeof RED !== 'undefined' && RED.floatingWindows) {
        console.log('RED.floatingWindows is available:', RED.floatingWindows);
        
        // Try to create a test window
        setTimeout(function() {
            var testWindow = RED.floatingWindows.create({
                id: 'test-window',
                title: 'Test Window',
                content: $('<div style="padding: 20px;">Floating windows are working!</div>'),
                x: 100,
                y: 100,
                width: 300,
                height: 200
            });
            console.log('Test window created:', testWindow);
        }, 1000);
    } else {
        console.log('RED.floatingWindows is not available');
    }
})();