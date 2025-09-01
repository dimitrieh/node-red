# Node-RED Floating Windows Implementation Plan

## Overview
Convert the Node-RED interface to have the node palette and sidebar as floating windows inside the node editor instead of fixed panels.

## Current Implementation Analysis

### Current Structure
1. **Node Palette** (`#red-ui-palette`)
   - Fixed position: `left: 0px`, width: `180px`
   - Contains categorized nodes (common, function, network, etc.)
   - Has search functionality and collapse/expand categories
   - Styled in `palette.scss`

2. **Sidebar** (`#red-ui-sidebar`) 
   - Fixed position: `right: 0px`, width: `315px`
   - Contains tabs: info, help, debug, config
   - Has tree view for flows and configuration
   - Styled in `sidebar.scss`

3. **Workspace**
   - Center area between fixed panels
   - Adjusts size based on panel visibility
   - Main canvas for node editing

## Implementation Plan

### Phase 1: CSS Modifications

#### 1.1 Palette Floating Window (`palette.scss`)
**Target**: Convert `#red-ui-palette` from fixed to floating window

**Changes needed:**
```css
#red-ui-palette {
  position: fixed; /* Change from absolute */
  top: 100px; /* Default starting position */
  left: 50px; /* Default starting position */
  width: 200px; /* Slightly wider for better UX */
  height: 400px; /* Fixed height */
  z-index: 1000; /* Above workspace */
  border: 1px solid var(--red-ui-primary-border-color);
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  resize: both; /* Allow resizing */
  overflow: hidden;
}
```

**Add floating window controls:**
- Title bar with drag handle
- Close/minimize buttons
- Resize functionality

#### 1.2 Sidebar Floating Window (`sidebar.scss`)
**Target**: Convert `#red-ui-sidebar` from fixed to floating window

**Changes needed:**
```css
#red-ui-sidebar {
  position: fixed; /* Change from absolute */
  top: 120px; /* Offset from palette */
  right: 50px; /* Default starting position */
  width: 320px;
  height: 450px; /* Fixed height */
  z-index: 1000; /* Above workspace */
  border: 1px solid var(--red-ui-primary-border-color);
  border-radius: 8px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.3);
  resize: both; /* Allow resizing */
  overflow: hidden;
}
```

#### 1.3 Workspace Adjustments
**Target**: Make workspace fill entire area

**Changes needed:**
- Remove left/right margins that accommodate fixed panels
- Workspace should span full width
- Remove separator elements

### Phase 2: JavaScript Enhancements

#### 2.1 Dragging Functionality
**Files to modify:**
- Create new `floating-windows.js` in `/src/js/ui/`
- Add drag functionality using jQuery UI draggable
- Implement window management (focus, z-index stacking)

**Features:**
```javascript
// Make windows draggable by title bar
$('#red-ui-palette, #red-ui-sidebar').draggable({
  handle: '.window-title-bar',
  containment: '#red-ui-editor',
  stack: '.floating-window'
});
```

#### 2.2 Window Controls
**Add title bars with:**
- Window title
- Minimize button
- Close button  
- Drag handle styling

#### 2.3 Resize Functionality
**Enable resizing with:**
- Corner resize handles
- Minimum/maximum size constraints
- Content reflow on resize

#### 2.4 State Management
**Implement:**
- Window position persistence (localStorage)
- Window visibility state
- Restore default positions function

### Phase 3: UI/UX Enhancements

#### 3.1 Visual Polish
- **Floating window styling:**
  - Rounded corners
  - Drop shadows
  - Semi-transparent title bars
  - Focus indicators

#### 3.2 User Controls
- **Menu options:**
  - "Reset Window Positions"
  - "Toggle Palette Window"
  - "Toggle Sidebar Window"
  
#### 3.3 Responsive Behavior
- **Small screens:**
  - Auto-minimize windows
  - Snap to edges option
  - Mobile-friendly touch targets

### Phase 4: File Modifications

#### 4.1 Core Files to Modify
1. **`packages/node_modules/@node-red/editor-client/src/sass/palette.scss`**
   - Convert from fixed to floating positioning
   - Add window styling

2. **`packages/node_modules/@node-red/editor-client/src/sass/sidebar.scss`**
   - Convert from fixed to floating positioning
   - Add window styling

3. **`packages/node_modules/@node-red/editor-client/src/sass/workspace.scss`**
   - Remove panel accommodations
   - Full-width workspace

4. **`packages/node_modules/@node-red/editor-client/src/js/ui/`** (new file)
   - `floating-windows.js` - Core floating window functionality

5. **`packages/node_modules/@node-red/editor-client/src/sass/style.scss`**
   - Import floating windows styles

#### 4.2 Additional Files
- Update any workspace sizing calculations
- Modify panel toggle functions
- Update responsive CSS media queries

### Expected Visual Changes

1. **Before**: Fixed left palette, fixed right sidebar, constrained center workspace
2. **After**: 
   - Floating palette window (draggable, resizable)
   - Floating sidebar window (draggable, resizable) 
   - Full-width workspace background
   - Windows can be positioned anywhere over workspace
   - Windows can be minimized/closed
   - Windows restore position on reload

### Implementation Steps

1. ✅ Take "before" screenshots
2. ✅ Analyze current CSS structure  
3. 🔄 Create implementation plan
4. ⏳ Modify palette.scss for floating behavior
5. ⏳ Modify sidebar.scss for floating behavior
6. ⏳ Create floating-windows.js functionality
7. ⏳ Update workspace.scss
8. ⏳ Test dragging and resizing
9. ⏳ Add window controls (minimize, close)
10. ⏳ Implement state persistence
11. ⏳ Take "after" screenshots
12. ⏳ User testing and polish

### Technical Considerations

- **Performance**: Use CSS transforms for smooth dragging
- **Z-index management**: Proper layering of floating windows
- **Responsive design**: Handle mobile/tablet viewports
- **Accessibility**: Keyboard navigation for window controls
- **Browser compatibility**: Test across modern browsers

### Risk Assessment

- **Low Risk**: CSS positioning changes
- **Medium Risk**: JavaScript drag/drop implementation  
- **High Risk**: Breaking existing workspace interactions

This plan maintains the current functionality while converting to a modern floating window interface.
