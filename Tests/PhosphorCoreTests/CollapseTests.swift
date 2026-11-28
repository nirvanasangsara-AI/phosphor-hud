import Foundation
import Testing
@testable import PhosphorCore

@Suite struct CollapseTests {
    @Test func newInstallIsDoubleClickAndExpanded() {
        let state = CollapseState.restored(mode: nil, remembered: nil, expanded: nil)
        #expect(state == .fresh)
        #expect(state.mode == .doubleClick)
        #expect(state.expanded)
        #expect(!state.pinned)
        #expect(Collapse.hoverLeaveDelay == 0.8)
    }

    @Test func unknownSavedModeFallsBackToDoubleClick() {
        let state = CollapseState.restored(mode: "hover", remembered: "pin", expanded: false)
        #expect(state.mode == .doubleClick)
        #expect(state.remembered == .doubleClick)
        #expect(!state.expanded)
    }

    @Test func pinAndAutoRestoreToTheirRestingFrames() {
        let pin = CollapseState.restored(mode: "pin", remembered: "auto", expanded: false)
        #expect(pin.mode == .pin)
        #expect(pin.remembered == .auto)
        #expect(pin.expanded)

        let auto = CollapseState.restored(mode: "auto", remembered: "doubleClick", expanded: true)
        #expect(auto.mode == .auto)
        #expect(auto.remembered == .auto)
        #expect(!auto.expanded)
        #expect(!auto.held)
        #expect(!auto.armed)
    }

    @Test func doubleClickTogglesOnlyInThatMode() {
        var state = CollapseState.fresh
        state = Collapse.reduce(state, .doubleClick)
        #expect(!state.expanded)
        state = Collapse.reduce(state, .doubleClick)
        #expect(state.expanded)

        let pinned = Collapse.reduce(state, .choose(.pin))
        #expect(Collapse.reduce(pinned, .doubleClick) == pinned)
        let auto = Collapse.reduce(.fresh, .choose(.auto))
        #expect(Collapse.reduce(auto, .doubleClick) == auto)
    }

    @Test func pinIgnoresHoverClickAndStaysOpen() {
        let pinned = Collapse.reduce(.fresh, .togglePin)
        #expect(pinned.pinned)
        #expect(pinned.expanded)
        #expect(pinned.remembered == .doubleClick)
        var state = pinned
        for event in [CollapseEvent.pointerEntered, .pointerExited, .delayElapsed, .clickStrip, .doubleClick] {
            state = Collapse.reduce(state, event)
        }
        #expect(state == pinned)
    }

    @Test func headerPinRestoresThePreviousMode() {
        var state = Collapse.reduce(.fresh, .choose(.auto))
        #expect(!state.expanded)
        state = Collapse.reduce(state, .togglePin)
        #expect(state.mode == .pin)
        #expect(state.remembered == .auto)
        #expect(state.expanded)
        state = Collapse.reduce(state, .togglePin)
        #expect(state.mode == .auto)
        #expect(!state.expanded)

        state = Collapse.reduce(.fresh, .togglePin)
        state = Collapse.reduce(state, .togglePin)
        #expect(state.mode == .doubleClick)
        #expect(state.expanded)
    }

    @Test func choosingAModeFromTheMenu() {
        var state = CollapseState.fresh
        state = Collapse.reduce(state, .doubleClick)
        #expect(!state.expanded)
        state = Collapse.reduce(state, .choose(.doubleClick))
        #expect(state.mode == .doubleClick)
        #expect(!state.expanded)

        state = Collapse.reduce(state, .choose(.auto))
        #expect(state.mode == .auto)
        #expect(state.remembered == .auto)
        #expect(!state.expanded)

        state = Collapse.reduce(state, .choose(.pin))
        #expect(state.pinned)
        #expect(state.remembered == .auto)
        #expect(state.expanded)

        state = Collapse.reduce(state, .choose(.doubleClick))
        #expect(state.mode == .doubleClick)
        #expect(state.remembered == .doubleClick)
        #expect(state.expanded)
    }

    @Test func autoHoverOpensAndFoldsAfterTheDelay() {
        var state = Collapse.reduce(.fresh, .choose(.auto))
        #expect(!state.expanded)
        state = Collapse.reduce(state, .pointerEntered)
        #expect(state.expanded)
        #expect(!state.armed)
        state = Collapse.reduce(state, .pointerExited)
        #expect(state.expanded)
        #expect(state.armed)
        let pending = state
        state = Collapse.reduce(state, .pointerEntered)
        #expect(state.expanded)
        #expect(!state.armed)
        #expect(Collapse.reduce(state, .delayElapsed) == state)
        state = Collapse.reduce(pending, .delayElapsed)
        #expect(!state.expanded)
        #expect(!state.armed)
    }

    @Test func clickHoldsAutoOpenUntilThePointerLeaves() {
        var state = Collapse.reduce(.fresh, .choose(.auto))
        state = Collapse.reduce(state, .pointerEntered)
        state = Collapse.reduce(state, .clickStrip)
        #expect(state.held)
        #expect(state.expanded)
        #expect(!state.armed)
        #expect(Collapse.reduce(state, .delayElapsed) == state)
        state = Collapse.reduce(state, .pointerExited)
        #expect(!state.expanded)
        #expect(!state.held)
        #expect(!state.armed)
    }

    @Test func clickOnAFoldedStripDoesNothingAndLeavingAFoldedStripDoesNothing() {
        let folded = Collapse.reduce(.fresh, .choose(.auto))
        #expect(Collapse.reduce(folded, .clickStrip) == folded)
        #expect(Collapse.reduce(folded, .pointerExited) == folded)
        #expect(Collapse.reduce(folded, .delayElapsed) == folded)
    }
}
