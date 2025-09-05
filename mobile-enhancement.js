// Enhanced Mobile & Tablet Script for Node-RED
// Comprehensive touch-optimized experience
(function() {
    'use strict';
    
    let mobileState = {
        isInitialized: false,
        activePanel: null,
        touchDevice: false,
        screenSize: 'desktop',
        orientation: 'portrait',
        connectionMode: false
    };
    
    // Enhanced device detection and setup
    function setupMobileEnhancements() {
        const width = window.innerWidth;
        const height = window.innerHeight;
        const isMobile = width <= 767;
        const isTablet = width >= 768 && width <= 1024;
        const isTouchDevice = 'ontouchstart' in window || navigator.maxTouchPoints > 0;
        
        mobileState.touchDevice = isTouchDevice;
        mobileState.orientation = width > height ? 'landscape' : 'portrait';
        mobileState.screenSize = isMobile ? 'mobile' : (isTablet ? 'tablet' : 'desktop');
        
        // Add comprehensive mobile classes to body
        document.body.className = document.body.className.replace(/red-ui-(mobile|tablet|desktop|touch|portrait|landscape)/g, '');
        document.body.classList.add(`red-ui-${mobileState.screenSize}`);
        document.body.classList.toggle('red-ui-touch', isTouchDevice);
        document.body.classList.add(`red-ui-${mobileState.orientation}`);
        
        if (mobileState.screenSize === 'mobile') {
            createMobileNavigation();
            hidePanelsOnMobile();
            enhanceTouchTargets();
            setupMobileWorkflow();
        } else if (mobileState.screenSize === 'tablet') {
            setupTabletLayout();
            enhanceTouchTargets();
        }
        
        if (mobileState.touchDevice) {
            addTouchEnhancements();
            setupAdvancedTouchGestures();
        }
        
        setupEventListeners();
        console.log('Enhanced Node-RED Mobile initialized for:', mobileState.screenSize);
    }
    
    function createMobileNavigation() {
        // Remove existing mobile nav
        const existingNav = document.querySelector('.red-ui-mobile-nav');
        if (existingNav) existingNav.remove();
        
        // Create enhanced mobile navigation bar
        const nav = document.createElement('div');
        nav.className = 'red-ui-mobile-nav';
        nav.style.cssText = `
            position: fixed;
            bottom: 20px;
            left: 50%;
            transform: translateX(-50%);
            background: var(--red-ui-primary-background, #ffffff);
            border: 1px solid var(--red-ui-primary-border-color, #d3d3d3);
            border-radius: 24px;
            padding: 8px 16px;
            box-shadow: 0 4px 16px rgba(0,0,0,0.15), 0 2px 8px rgba(0,0,0,0.1);
            z-index: 1001;
            display: flex;
            gap: 12px;
            align-items: center;
            backdrop-filter: blur(10px);
        `;
        
        // Enhanced navigation buttons
        const paletteBtn = createNavButton('📦', 'Toggle Palette', () => toggleMobilePanel('palette'));
        paletteBtn.setAttribute('data-panel', 'palette');
        
        const homeBtn = createNavButton('🏠', 'Center View', centerWorkspace);
        
        const deployBtn = createNavButton('🚀', 'Deploy', () => {
            if (window.RED && RED.deploy) RED.deploy.trigger();
        });
        deployBtn.classList.add('deploy-button');
        
        const infoBtn = createNavButton('ℹ️', 'Toggle Info', () => toggleMobilePanel('sidebar'));
        infoBtn.setAttribute('data-panel', 'sidebar');
        
        const settingsBtn = createNavButton('⚙️', 'Settings', () => {
            if (window.RED && RED.userSettings) RED.userSettings.toggle();
        });
        
        [paletteBtn, homeBtn, deployBtn, infoBtn, settingsBtn].forEach(btn => nav.appendChild(btn));
        
        document.body.appendChild(nav);
    }
    
    function createNavButton(icon, title, onClick) {
        const button = document.createElement('button');
        button.className = 'nav-button';
        button.style.cssText = `
            background: none;
            border: none;
            font-size: 18px;
            padding: 8px;
            border-radius: 50%;
            min-width: 44px;
            min-height: 44px;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
            transition: all 0.2s ease;
        `;
        button.textContent = icon;
        button.title = title;
        button.setAttribute('aria-label', title);
        
        // Enhanced touch feedback
        button.addEventListener('touchstart', (e) => {
            e.preventDefault();
            button.style.transform = 'scale(0.9)';
            if ('vibrate' in navigator) navigator.vibrate(10);
        });
        
        button.addEventListener('touchend', (e) => {
            e.preventDefault();
            button.style.transform = '';
            onClick();
        });
        
        button.addEventListener('click', (e) => {
            if (!mobileState.touchDevice) onClick();
        });
        
        // Add hover/focus effects
        button.addEventListener('mouseenter', () => {
            button.style.background = 'var(--red-ui-node-selected-color, rgba(0,123,255,0.1))';
            button.style.transform = 'scale(1.05)';
        });
        
        button.addEventListener('mouseleave', () => {
            button.style.background = 'none';
            button.style.transform = '';
        });
        
        button.addEventListener('focus', () => {
            button.style.background = 'var(--red-ui-node-selected-color, rgba(0,123,255,0.1))';
        });
        
        button.addEventListener('blur', () => {
            button.style.background = 'none';
        });
        
        return button;
    }
    
    function hidePanelsOnMobile() {
        if (window.innerWidth <= 767) {
            const sidebar = document.getElementById('red-ui-sidebar');
            const palette = document.getElementById('red-ui-palette');
            
            if (sidebar) {
                sidebar.style.display = 'none';
                sidebar.dataset.mobileHidden = 'true';
            }
            
            if (palette) {
                palette.style.display = 'none';
                palette.dataset.mobileHidden = 'true';
            }
            
            // Ensure workspace uses full width
            const workspace = document.getElementById('red-ui-workspace');
            if (workspace) {
                workspace.style.left = '0px';
                workspace.style.right = '0px';
            }
        }
    }
    
    // Toggle mobile panel visibility
    function toggleMobilePanel(panelType) {
        const panelId = panelType === 'palette' ? 'red-ui-palette' : 'red-ui-sidebar';
        const panel = document.getElementById(panelId);
        const button = document.querySelector(`[data-panel="${panelType}"]`);
        
        if (!panel) return;
        
        const isVisible = panel.classList.contains('mobile-visible');
        
        // Hide all other panels first
        hideAllMobilePanels();
        
        if (!isVisible) {
            // Show this panel
            panel.classList.add('mobile-visible');
            panel.style.transform = 'translateX(0)';
            panel.style.position = 'fixed';
            panel.style.top = 'var(--red-ui-header-height, 48px)';
            panel.style.bottom = '80px';
            panel.style.zIndex = '1000';
            panel.style.boxShadow = '2px 0 12px rgba(0,0,0,0.15)';
            
            if (panelType === 'sidebar') {
                panel.style.right = '0';
                panel.style.width = 'min(320px, 90vw)';
                panel.style.left = 'auto';
            } else if (panelType === 'palette') {
                panel.style.left = '0';
                panel.style.width = 'min(300px, 85vw)';
            }
            
            if (button) button.classList.add('active');
            mobileState.activePanel = panelType;
            showMobileOverlay();
        } else {
            mobileState.activePanel = null;
            hideMobileOverlay();
        }
    }
    
    // Hide all mobile panels
    function hideAllMobilePanels() {
        const panels = ['red-ui-palette', 'red-ui-sidebar'];
        const buttons = document.querySelectorAll('.nav-button[data-panel]');
        
        panels.forEach(id => {
            const panel = document.getElementById(id);
            if (panel) {
                panel.classList.remove('mobile-visible');
                if (id === 'red-ui-palette') {
                    panel.style.transform = 'translateX(-100%)';
                } else {
                    panel.style.transform = 'translateX(100%)';
                }
            }
        });
        
        buttons.forEach(btn => btn.classList.remove('active'));
        mobileState.activePanel = null;
        hideMobileOverlay();
    }
    
    // Show/hide mobile overlay
    function showMobileOverlay() {
        let overlay = document.querySelector('.red-ui-mobile-overlay');
        if (!overlay) {
            overlay = document.createElement('div');
            overlay.className = 'red-ui-mobile-overlay';
            overlay.style.cssText = `
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(0,0,0,0.5);
                z-index: 999;
                transition: opacity 0.3s ease;
                backdrop-filter: blur(2px);
            `;
            document.body.appendChild(overlay);
        }
        
        overlay.addEventListener('click', hideAllMobilePanels);
        overlay.addEventListener('touchstart', hideAllMobilePanels);
    }

    function hideMobileOverlay() {
        const overlay = document.querySelector('.red-ui-mobile-overlay');
        if (overlay) overlay.remove();
    }

    // Setup tablet layout
    function setupTabletLayout() {
        const palette = document.getElementById('red-ui-palette');
        const sidebar = document.getElementById('red-ui-sidebar');
        
        [palette, sidebar].forEach((panel, index) => {
            if (panel) {
                panel.style.position = 'fixed';
                panel.style.zIndex = '100';
                panel.style.boxShadow = '0 0 16px rgba(0,0,0,0.15)';
                panel.style.borderRadius = '8px';
                panel.style.top = '60px';
                panel.style.height = 'calc(100vh - 120px)';
                
                if (index === 0) { // palette
                    panel.style.left = '20px';
                    panel.style.width = '220px';
                } else { // sidebar
                    panel.style.right = '20px';
                    panel.style.width = '280px';
                }
                
                addMinimizeButton(panel, index === 0 ? 'palette' : 'sidebar');
            }
        });
    }

    function addMinimizeButton(panel, type) {
        if (panel.querySelector('.tablet-minimize-btn')) return;
        
        const btn = document.createElement('button');
        btn.className = 'tablet-minimize-btn';
        btn.innerHTML = '⬇️';
        btn.title = `Minimize ${type}`;
        btn.style.cssText = `
            position: absolute;
            top: 4px;
            right: 4px;
            width: 32px;
            height: 32px;
            border: none;
            background: rgba(0,0,0,0.1);
            border-radius: 6px;
            cursor: pointer;
            z-index: 10;
            font-size: 16px;
            display: flex;
            align-items: center;
            justify-content: center;
        `;
        
        btn.addEventListener('click', () => {
            panel.classList.toggle('tablet-minimized');
            if (panel.classList.contains('tablet-minimized')) {
                panel.style.height = '48px';
                panel.style.overflow = 'hidden';
                btn.innerHTML = '⬆️';
            } else {
                panel.style.height = 'calc(100vh - 120px)';
                panel.style.overflow = '';
                btn.innerHTML = '⬇️';
            }
        });
        
        panel.style.position = 'relative';
        panel.appendChild(btn);
    }

    // Setup mobile workflow enhancements
    function setupMobileWorkflow() {
        createConnectionToggle();
        createZoomControls();
    }

    function createConnectionToggle() {
        const toggleBtn = document.createElement('button');
        toggleBtn.className = 'mobile-connection-toggle';
        toggleBtn.innerHTML = '🔗';
        toggleBtn.title = 'Toggle Connection Mode';
        toggleBtn.style.cssText = `
            position: fixed;
            top: 100px;
            right: 20px;
            width: 48px;
            height: 48px;
            border: none;
            border-radius: 50%;
            background: var(--red-ui-primary-background, #fff);
            box-shadow: 0 2px 8px rgba(0,0,0,0.2);
            z-index: 1001;
            font-size: 20px;
            cursor: pointer;
            transition: all 0.2s ease;
            display: flex;
            align-items: center;
            justify-content: center;
        `;

        toggleBtn.addEventListener('click', () => {
            mobileState.connectionMode = !mobileState.connectionMode;
            toggleBtn.style.background = mobileState.connectionMode 
                ? 'var(--red-ui-deploy-button-color, #8f0000)' 
                : 'var(--red-ui-primary-background, #fff)';
            toggleBtn.style.color = mobileState.connectionMode ? 'white' : 'inherit';
        });

        document.body.appendChild(toggleBtn);
    }

    function createZoomControls() {
        const zoomControls = document.createElement('div');
        zoomControls.className = 'mobile-zoom-controls';
        zoomControls.style.cssText = `
            position: fixed;
            bottom: 100px;
            right: 20px;
            display: flex;
            flex-direction: column;
            gap: 8px;
            z-index: 1001;
        `;

        const zoomButtons = [
            { text: '+', title: 'Zoom In', action: () => zoomWorkspace(1.2) },
            { text: '−', title: 'Zoom Out', action: () => zoomWorkspace(0.8) },
            { text: '◎', title: 'Fit to View', action: () => fitWorkspace() }
        ];

        zoomButtons.forEach(({ text, title, action }) => {
            const btn = document.createElement('button');
            btn.textContent = text;
            btn.title = title;
            btn.style.cssText = `
                width: 44px;
                height: 44px;
                border: none;
                border-radius: 50%;
                background: var(--red-ui-primary-background, #fff);
                box-shadow: 0 2px 8px rgba(0,0,0,0.2);
                font-size: 20px;
                font-weight: bold;
                cursor: pointer;
                display: flex;
                align-items: center;
                justify-content: center;
            `;
            btn.addEventListener('click', action);
            zoomControls.appendChild(btn);
        });

        document.body.appendChild(zoomControls);
    }

    function zoomWorkspace(factor) {
        if (window.RED && RED.view) {
            RED.view.scale(RED.view.scale() * factor, [0, 0]);
        }
    }

    function fitWorkspace() {
        if (window.RED && RED.view) {
            RED.view.focus();
        }
    }

    // Setup advanced touch gestures
    function setupAdvancedTouchGestures() {
        const workspace = document.getElementById('red-ui-workspace-chart');
        if (!workspace) return;

        let initialDistance = 0;
        let initialScale = 1;
        
        workspace.addEventListener('touchstart', (e) => {
            if (e.touches.length === 2) {
                const touch1 = e.touches[0];
                const touch2 = e.touches[1];
                initialDistance = Math.hypot(
                    touch2.clientX - touch1.clientX,
                    touch2.clientY - touch1.clientY
                );
                
                if (window.RED && RED.view) {
                    initialScale = RED.view.scale();
                }
            }
        });

        workspace.addEventListener('touchmove', (e) => {
            if (e.touches.length === 2 && window.RED && RED.view) {
                e.preventDefault();
                
                const touch1 = e.touches[0];
                const touch2 = e.touches[1];
                const currentDistance = Math.hypot(
                    touch2.clientX - touch1.clientX,
                    touch2.clientY - touch1.clientY
                );
                
                const scale = initialScale * (currentDistance / initialDistance);
                const center = [
                    (touch1.clientX + touch2.clientX) / 2,
                    (touch1.clientY + touch2.clientY) / 2
                ];
                
                RED.view.scale(Math.max(0.1, Math.min(3, scale)), center);
            }
        }, { passive: false });
    }

    // Setup responsive event listeners
    function setupEventListeners() {
        let resizeTimeout;
        
        window.addEventListener('resize', () => {
            clearTimeout(resizeTimeout);
            resizeTimeout = setTimeout(() => {
                const oldScreenSize = mobileState.screenSize;
                setupMobileEnhancements(); // Re-detect and setup
                
                if (oldScreenSize !== mobileState.screenSize) {
                    console.log('Screen size changed:', oldScreenSize, '->', mobileState.screenSize);
                }
            }, 100);
        });
        
        window.addEventListener('orientationchange', () => {
            setTimeout(() => {
                setupMobileEnhancements();
                if (mobileState.screenSize === 'mobile') {
                    hideAllMobilePanels();
                }
            }, 100);
        });
        
        document.addEventListener('visibilitychange', () => {
            if (document.hidden && mobileState.screenSize === 'mobile') {
                hideAllMobilePanels();
            }
        });
    }
    
    function togglePanel(selector, type) {
        const panel = document.querySelector(selector);
        if (!panel) return;
        
        const isVisible = panel.style.display !== 'none';
        
        if (isVisible) {
            // Hide panel
            panel.style.display = 'none';
            panel.dataset.mobileHidden = 'true';
        } else {
            // Show panel
            panel.style.display = 'block';
            panel.style.position = 'fixed';
            panel.style.top = 'var(--red-ui-header-height, 48px)';
            panel.style.zIndex = '1000';
            panel.style.boxShadow = '0 4px 12px rgba(0,0,0,0.2)';
            
            if (type === 'sidebar') {
                panel.style.right = '0';
                panel.style.width = '300px';
            } else if (type === 'palette') {
                panel.style.left = '0';
                panel.style.width = '280px';
            }
            
            panel.dataset.mobileHidden = 'false';
        }
        
        // Add overlay
        toggleOverlay(isVisible);
    }
    
    function toggleOverlay(hide) {
        const existingOverlay = document.querySelector('.mobile-panel-overlay');
        
        if (hide && existingOverlay) {
            existingOverlay.remove();
        } else if (!hide && !existingOverlay) {
            const overlay = document.createElement('div');
            overlay.className = 'mobile-panel-overlay';
            overlay.style.cssText = `
                position: fixed;
                top: 0;
                left: 0;
                right: 0;
                bottom: 0;
                background: rgba(0,0,0,0.5);
                z-index: 999;
                cursor: pointer;
            `;
            
            overlay.addEventListener('click', () => {
                // Hide all panels
                const sidebar = document.getElementById('red-ui-sidebar');
                const palette = document.getElementById('red-ui-palette');
                
                if (sidebar && sidebar.dataset.mobileHidden === 'false') {
                    sidebar.style.display = 'none';
                    sidebar.dataset.mobileHidden = 'true';
                }
                
                if (palette && palette.dataset.mobileHidden === 'false') {
                    palette.style.display = 'none';
                    palette.dataset.mobileHidden = 'true';
                }
                
                overlay.remove();
            });
            
            document.body.appendChild(overlay);
        }
    }
    
    function enhanceTouchTargets() {
        const style = document.createElement('style');
        style.textContent = `
            /* Touch-friendly enhancements */
            .red-ui-header-button,
            .red-ui-button,
            .red-ui-deploy-button {
                min-height: 44px !important;
                min-width: 44px !important;
                padding: 8px 12px !important;
            }
            
            .red-ui-palette-node {
                min-height: 44px !important;
                padding: 8px 12px !important;
                margin: 4px 2px !important;
            }
            
            .red-ui-sidebar-tab {
                min-height: 44px !important;
                line-height: 44px !important;
            }
            
            .red-ui-tabs li {
                min-height: 44px !important;
            }
            
            .red-ui-tabs li a {
                padding: 12px 16px !important;
                line-height: 20px !important;
            }
        `;
        document.head.appendChild(style);
    }
    
    function addTouchEnhancements() {
        const workspace = document.getElementById('red-ui-workspace-chart');
        if (workspace) {
            workspace.style.webkitOverflowScrolling = 'touch';
            workspace.style.scrollBehavior = 'smooth';
        }
        
        // Add touch feedback to nodes
        document.addEventListener('touchstart', (e) => {
            if (e.target.closest('.red-ui-palette-node, .red-ui-button')) {
                e.target.style.transform = 'scale(0.95)';
            }
        });
        
        document.addEventListener('touchend', (e) => {
            if (e.target.closest('.red-ui-palette-node, .red-ui-button')) {
                setTimeout(() => {
                    e.target.style.transform = '';
                }, 150);
            }
        });
    }
    
    function centerWorkspace() {
        // Try to center the workspace view
        if (window.RED && RED.view && RED.view.focus) {
            RED.view.focus();
        }
    }
    
    function handleOrientationChange() {
        setTimeout(() => {
            setupMobileEnhancements();
        }, 100);
    }
    
    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', setupMobileEnhancements);
    } else {
        setupMobileEnhancements();
    }
    
    // Handle orientation changes
    window.addEventListener('orientationchange', handleOrientationChange);
    window.addEventListener('resize', handleOrientationChange);
    
    console.log('Node-RED Mobile Enhancements Loaded');
})();