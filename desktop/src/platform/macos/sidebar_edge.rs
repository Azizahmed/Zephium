//! A hidden sidebar waits beneath the page, so the page's own view takes
//! every pointer move along the window's left edge and the chrome never sees
//! the pointer arrive. Reading the moves app-wide tells the chrome the moment
//! the pointer reaches the edge, or is plainly about to.

use std::cell::RefCell;
use std::ptr::NonNull;

use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_app_kit::{NSEvent, NSEventMask, NSWindow};
use objc2_foundation::MainThreadMarker;
use tauri::{Manager, WebviewWindow};

/// Within this of the window's left edge the pointer is at it: the gutter
/// before the page and a hair of the page's own edge.
const REACH: f64 = 10.0;
/// Further in, a pointer moving fast enough to cross the edge within the
/// next couple of moves is taken as already there, so the column is on its
/// way before the pointer lands.
const APPROACH: f64 = 56.0;
const LEAD: f64 = 2.0;

struct Edge {
    window: WebviewWindow,
    number: isize,
    near: bool,
    last: Option<f64>,
}

thread_local! {
    static EDGES: RefCell<Vec<Edge>> = const { RefCell::new(Vec::new()) };
    static MONITOR: RefCell<Option<Retained<AnyObject>>> = const { RefCell::new(None) };
}

/// Whether a pointer at `x` that last moved by `step` is at the edge. Once
/// there, it stays until it is clearly inside the page, so a pointer resting
/// on the boundary does not flicker the column.
fn at_edge(x: f64, step: f64, near: bool) -> bool {
    if near {
        return x <= APPROACH;
    }
    x <= REACH || (x < APPROACH && step < 0.0 && x + step * LEAD <= 0.0)
}

fn observe(event: &NSEvent) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let Some(window) = event.window(mtm) else {
        return;
    };
    let number = window.windowNumber();
    let x = event.locationInWindow().x;
    let changed = EDGES.with(|edges| {
        let mut edges = edges.try_borrow_mut().ok()?;
        let edge = edges.iter_mut().find(|edge| edge.number == number)?;
        let step = edge.last.map_or(0.0, |last| x - last);
        edge.last = Some(x);
        let near = at_edge(x, step, edge.near);
        (near != edge.near).then(|| {
            edge.near = near;
            (edge.window.clone(), near)
        })
    });
    if let Some((window, near)) = changed {
        crate::emit_to_privileged(
            window.app_handle(),
            window.label(),
            "zephium:sidebar-edge",
            &serde_json::json!({ "near": near }),
        );
    }
}

/// Starts or stops watching `window`'s left edge. Runs on the main thread.
pub fn watch(window: &WebviewWindow, on: bool) {
    if MainThreadMarker::new().is_none() {
        return;
    }
    let Ok(pointer) = window.ns_window() else {
        return;
    };
    // SAFETY: Tao's live NSWindow, borrowed for this main-thread call only.
    let number = unsafe { &*(pointer as *const NSWindow) }.windowNumber();
    let watching = EDGES.with(|edges| {
        let mut edges = edges.borrow_mut();
        edges.retain(|edge| edge.number != number);
        if on {
            edges.push(Edge {
                window: window.clone(),
                number,
                near: false,
                last: None,
            });
        }
        !edges.is_empty()
    });
    MONITOR.with(|monitor| {
        let mut monitor = monitor.borrow_mut();
        match (watching, monitor.is_some()) {
            (true, false) => {
                let handler = RcBlock::new(|event: NonNull<NSEvent>| -> *mut NSEvent {
                    // SAFETY: the local monitor lends its event for this call.
                    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        observe(unsafe { event.as_ref() })
                    }));
                    event.as_ptr()
                });
                // SAFETY: an app-local main-thread monitor that hands every
                // event back untouched.
                *monitor = unsafe {
                    NSEvent::addLocalMonitorForEventsMatchingMask_handler(
                        NSEventMask::MouseMoved,
                        &handler,
                    )
                };
            }
            (false, true) => {
                if let Some(old) = monitor.take() {
                    // SAFETY: this exact registration is removed once.
                    unsafe { NSEvent::removeMonitor(&old) };
                }
            }
            _ => {}
        }
    });
}

#[cfg(test)]
mod tests {
    use super::at_edge;

    #[test]
    fn the_edge_is_reached_or_about_to_be() {
        assert!(at_edge(0.0, 0.0, false));
        assert!(at_edge(10.0, 3.0, false));
        assert!(!at_edge(30.0, 0.0, false));
        // Fast toward the edge: there within two moves.
        assert!(at_edge(40.0, -24.0, false));
        // Slowly toward it, or away from it, is not yet.
        assert!(!at_edge(40.0, -6.0, false));
        assert!(!at_edge(40.0, 24.0, false));
        // Once there, resting nearby keeps it.
        assert!(at_edge(40.0, 0.0, true));
        assert!(!at_edge(80.0, 0.0, true));
    }
}
