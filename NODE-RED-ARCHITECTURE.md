# Node-RED Architecture Guide for AI Assistants

## Project Structure Overview

Node-RED is a monorepo with the following structure:
```
node-red/
├── packages/node_modules/@node-red/  # Core packages
│   ├── editor-client/    # Frontend UI (browser-side)
│   ├── editor-api/       # REST API for editor
│   ├── runtime/          # Flow execution engine
│   ├── registry/         # Node registry management
│   ├── nodes/            # Core nodes (inject, debug, etc.)
│   └── util/             # Shared utilities
├── Gruntfile.js          # Build configuration
└── package.json          # Main project config
```

## Key Components

### 1. Editor Client (Frontend)
**Location:** `packages/node_modules/@node-red/editor-client/src/`

**JavaScript Structure (`src/js/`):**
- `red.js` - Main editor initialization
- `main.js` - Application entry point
- `ui/` - UI components
  - `view.js` - Main canvas/workspace view
  - `palette.js` - Node palette (left sidebar)
  - `sidebar.js` - Right sidebar container
  - `workspaces.js` - Flow tabs management
  - `deploy.js` - Deploy button functionality
  - `editor.js` - Node editor dialog
  - `common/` - Reusable UI widgets (tabs, menus, popover, etc.)

**Styling (`src/sass/`):**
- `style.scss` - Main stylesheet entry
- `flow.scss` - Workspace/canvas styles
- `palette.scss` - Node palette styles
- `sidebar.scss` - Sidebar styles
- `header.scss` - Header/toolbar styles
- `colors.scss` - Color definitions
- `variables.scss` - SASS variables

**HTML Template:**
- `src/index.html` - Main HTML template

### 2. Key UI Areas

**Main Editor Components:**
1. **Header** - Top bar with deploy button, user menu
2. **Palette** - Left sidebar with available nodes
3. **Workspace** - Central canvas for flow editing
4. **Sidebar** - Right panel with info/debug/config tabs
5. **Footer** - Status bar at bottom

**CSS Classes:**
- `.red-ui-workspace` - Main workspace container
- `.red-ui-palette` - Node palette
- `.red-ui-sidebar` - Right sidebar
- `.red-ui-header` - Top header
- `.red-ui-view` - Flow canvas view

### 3. Build System

**Commands:**
- `npm run build` - Full build (runs Grunt)
- `npm run dev` - Development mode with watch
- `grunt build` - Compiles SASS, concatenates JS

**Build Process:**
1. SASS compilation: `src/sass/` → `public/red/style.css`
2. JS concatenation: `src/js/` → `public/red/red.js`
3. Assets copied to `public/`

### 4. Common File Patterns

**For UI changes, check these files:**
- Visual styling: `packages/node_modules/@node-red/editor-client/src/sass/*.scss`
- Component logic: `packages/node_modules/@node-red/editor-client/src/js/ui/*.js`
- Main initialization: `packages/node_modules/@node-red/editor-client/src/js/red.js`

**File naming conventions:**
- `tab-*.js` - Sidebar tab implementations
- `ui/common/*.js` - Reusable UI widgets
- `ui/editors/*.js` - Property editor components

### 5. Important Implementation Details

**jQuery Usage:**
- Node-RED uses jQuery extensively
- Most UI components are jQuery plugins
- DOM selections use `$()` not vanilla JS

**RED Namespace:**
- Global `RED` object contains all editor functionality
- `RED.view` - Canvas/workspace methods
- `RED.palette` - Palette management
- `RED.sidebar` - Sidebar tabs
- `RED.nodes` - Node registry

**Event System:**
- `RED.events.on()` / `RED.events.emit()` for communication
- Common events: "workspace:change", "nodes:add", "deploy"

### 6. Making UI Changes

**Typical workflow:**
1. Identify the UI component in `src/js/ui/`
2. Locate corresponding styles in `src/sass/`
3. Make changes to both JS and SCSS files
4. Run `npm run build` to compile
5. Refresh browser (changes visible at http://localhost:1880)

**After frontend changes:**
- Always run `npm run build`
- No need to restart Node-RED server
- Just refresh the browser

**After backend changes:**
- Restart Node-RED server
- Use: `kill $(cat node-red.pid) && npm start & && echo $! > node-red.pid`

## Quick Reference for Common Tasks

### Finding UI Components
```bash
# Find a UI element by class name
grep -r "className" packages/node_modules/@node-red/editor-client/src/

# Find SASS styles
grep -r "selector" packages/node_modules/@node-red/editor-client/src/sass/

# Find JavaScript component
grep -r "componentName" packages/node_modules/@node-red/editor-client/src/js/
```

### Key Files for Common UI Areas
- **Deploy Button**: `src/js/ui/deploy.js`, `src/sass/header.scss`
- **Node Palette**: `src/js/ui/palette.js`, `src/sass/palette.scss`
- **Sidebar Tabs**: `src/js/ui/sidebar.js`, `src/sass/sidebar.scss`
- **Workspace Canvas**: `src/js/ui/view.js`, `src/sass/flow.scss`
- **Node Editor Dialog**: `src/js/ui/editor.js`, `src/sass/editor.scss`

## Mobile/Responsive Considerations

Node-RED was designed primarily for desktop use:
- Minimum expected width: 1024px
- Mobile layouts (< 768px) may have overlapping UI elements
- Sidebar can cover workspace on narrow screens
- Touch interactions have limited support

When testing at different resolutions, be aware:
- Sidebar may need to be hidden on mobile
- Palette may overlap workspace
- Some interactions require hover (not touch-friendly)