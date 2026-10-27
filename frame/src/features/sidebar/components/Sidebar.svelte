<script lang="ts">
  import * as m from "$shared/i18n/messages";
  import type { Snippet } from "svelte";
  import { IS_MAC, IS_WINDOWS } from "$shared/platform";
  import * as motion from "$session/motion.svelte";
  import { surface as browserPage } from "$domain/surface";
  import { tabs } from "$domain/tabs";
  import * as tools from "$session/tools.svelte";
  import { untrack } from "svelte";
  import {
    COMPACT_WIDTH,
    PANEL_GAP,
    effectiveWidth,
    holdShown,
    isCompact,
    isHidden,
    sidebarResizeActive,
    sidebarResizeSettlement,
    toggleMode,
  } from "$session/sidebar-mode.svelte";
  import { commands } from "$shared/ipc/bindings";
  import { FROSTS, scene } from "$shared/sky";
  import { uiCommands as ui } from "$domain/ui-commands";
  import SidebarHeader from "./SidebarHeader.svelte";
  import * as shapeMorph from "../lib/shape-morph";
  import { duration, reducedMotion } from "$shared/lib/motion";
  import SidebarResizeHandle from "./SidebarResizeHandle.svelte";

  let {
    settingsNavigation,
    toolPanel,
    browserBody,
    dock,
  }: {
    settingsNavigation: Snippet;
    toolPanel: Snippet<[tools.ToolKind]>;
    browserBody: Snippet<[boolean]>;
    dock: Snippet<[boolean]>;
  } = $props();
  let settings = $derived(browserPage.currentPage() === "settings");
  const SETTINGS_PANEL = 264;
  let taskPage = $derived(
    browserPage.currentPage() === "tasks" || browserPage.currentPage() === "notes",
  );
  // Work gives the window to its canvas: the column is always the rail there.
  let inWork = $derived(browserPage.currentPage() === "work");
  let railPage = $derived(taskPage || inWork);
  // Work keeps the column as its compact rail, always: a panel open in Browse
  // closes on the way in, and a tool asked for while in Work opens over its
  // canvas instead of beside it.
  let settledInWork = false;
  $effect(() => {
    const tool = tools.activeTool();
    const work = inWork;
    untrack(() => {
      if (work && tool !== null) {
        tools.close();
        if (settledInWork)
          window.dispatchEvent(new CustomEvent("zephium:work-tool", { detail: tool }));
      }
      settledInWork = work;
    });
  });
  // Settings opens like a tool: the column keeps its tab rail, and its sections
  // stand in the panel beside it while the page shows the section. Tasks and
  // Notes are part of browsing too: a tab is one click away and choosing it
  // returns to that page.
  let navigating = $derived(settings);
  let paneled = $derived(settings || tools.activeTool() !== null);
  let compact = $derived(navigating || railPage || isCompact() || tools.activeTool() !== null);
  // Work, Tasks, Settings and the tools want the column in view as their rail.
  $effect(() => {
    holdShown(navigating || railPage || tools.activeTool() !== null);
  });

  // Hidden, the column waits off to the side, beneath the page, and comes
  // over it as a card as the pointer reaches the window's left edge. The
  // page's own view takes the pointer there, so native watches the edge.
  let hidden = $derived(isHidden());
  // A page hides the column by sliding over it, so the column keeps its
  // shape until it is covered and only then becomes the card; anything the
  // chrome draws itself has nothing to slide, and lets the column go at once.
  let overPage = $derived(
    browserPage.currentPage() === null && !!tabs.activeTab()?.url && !tabs.activeTab()?.loading,
  );
  let away = $state(isHidden());
  $effect(() => {
    if (!hidden) {
      away = false;
      return;
    }
    if (untrack(() => away)) return;
    if (!untrack(() => overPage) || reducedMotion()) {
      away = true;
      return;
    }
    const covered = setTimeout(() => (away = true), duration("page"));
    return () => clearTimeout(covered);
  });
  // The column becomes the card already out of sight: only from the next
  // frame on does the card slide, so it never crosses the window's gutter.
  let armed = $state(false);
  $effect(() => {
    if (!away) {
      armed = false;
      return;
    }
    let live = true;
    requestAnimationFrame(() => requestAnimationFrame(() => live && (armed = true)));
    return () => {
      live = false;
    };
  });
  let aside = $state<HTMLElement>();
  let peeking = $state(false);
  let atEdge = false;
  /** Leaving the card gives it a moment: a pointer overshooting its edge
   *  and coming straight back should not see it go and return. */
  const LINGER_MS = 180;
  let linger: ReturnType<typeof setTimeout> | undefined;
  let lowered: ReturnType<typeof setTimeout> | undefined;
  function peek() {
    clearTimeout(linger);
    clearTimeout(lowered);
    if (peeking) {
      void commands.sidebarPeek(true, true);
      return;
    }
    // Native stacks the chrome over the page before the card slides in, so
    // the slide is seen from its first frame.
    void commands.sidebarPeek(true, true).then(() =>
      requestAnimationFrame(() => {
        if (away) peeking = true;
      }),
    );
  }
  /** Something in the card still needs it: a field being typed in, an open
   *  panel, or a drag. */
  const needed = () => {
    if (!aside || sidebarResizeActive()) return !!aside;
    const typing =
      document.activeElement instanceof HTMLInputElement && aside.contains(document.activeElement);
    return typing || !!aside.querySelector('[data-open="true"]');
  };
  function release() {
    clearTimeout(linger);
    linger = setTimeout(() => {
      if (pointerIn || atEdge || needed()) return;
      peeking = false;
      // The controls go as the card starts to; the chrome goes back beneath
      // the page once the card has slid away.
      void commands.sidebarPeek(true, false);
      lowered = setTimeout(() => void commands.sidebarPeek(false, false), duration("page"));
    }, LINGER_MS);
  }
  $effect(() => {
    const edge = (event: Event) => {
      if (!(event instanceof CustomEvent) || typeof event.detail?.near !== "boolean") return;
      atEdge = event.detail.near;
      if (!away) return;
      if (atEdge) peek();
      else if (peeking && !pointerIn) release();
    };
    window.addEventListener("zephium:sidebar-edge", edge);
    return () => window.removeEventListener("zephium:sidebar-edge", edge);
  });
  $effect(() => {
    if (away) return;
    clearTimeout(linger);
    clearTimeout(lowered);
    untrack(() => {
      if (peeking) void commands.sidebarPeek(false, false);
      peeking = false;
    });
  });
  $effect(() => () => {
    clearTimeout(linger);
    clearTimeout(lowered);
  });

  // A change of shape is one continuous change: every mark travels from the
  // old shape into the new one while native slides the page to match. Not
  // on the first shape, which launch brings in with its own cascade.
  let columns = $state<HTMLElement>();
  let shown: boolean | null = null;
  let morph: ReturnType<typeof shapeMorph.capture> = null;
  // While the shape changes, the column's width travels with the page
  // instead of jumping, and its contents hold their final width so only the
  // space beside them moves. A resize guide commits its width immediately on release.
  let reshaping = $state(false);
  let resizeSettling = $state(false);
  let observedResizeSettlement = sidebarResizeSettlement();
  // The header only fades in when it is the other header, not merely beside
  // a column that changed (a tool opening keeps the same header).
  let headerCompact = $derived(compact && !paneled);
  let headerFresh = $state(false);
  let shownHeader: boolean | null = null;
  let reshaped: ReturnType<typeof setTimeout> | undefined;
  $effect(() => () => clearTimeout(reshaped));
  $effect.pre(() => {
    const next = compact;
    const head = headerCompact;
    const settlement = sidebarResizeSettlement();
    untrack(() => {
      // A drag that only changes the width lands at once; one that snaps the
      // column to the other shape travels like any change of shape, since
      // native slides the page with it.
      if (settlement !== observedResizeSettlement && (shown === null || shown === next)) {
        observedResizeSettlement = settlement;
        resizeSettling = true;
        queueMicrotask(() => {
          if (observedResizeSettlement === settlement) resizeSettling = false;
        });
        morph = null;
        reshaping = false;
        headerFresh = false;
        clearTimeout(reshaped);
        shown = next;
        shownHeader = head;
        return;
      }
      observedResizeSettlement = settlement;
      const headChanged = shownHeader !== null && shownHeader !== head;
      shownHeader = head;
      if (shown === null || shown === next) return;
      morph = shapeMorph.capture(columns);
      if (reducedMotion()) return;
      reshaping = true;
      headerFresh = headChanged;
      clearTimeout(reshaped);
      reshaped = setTimeout(
        () => {
          reshaping = false;
          headerFresh = false;
        },
        duration("page") + 40,
      );
    });
  });
  $effect(() => {
    const next = compact;
    untrack(() => {
      if (shown !== null && shown !== next) shapeMorph.play(morph);
      morph = null;
      shown = next;
    });
  });
  let width = $derived(
    navigating
      ? COMPACT_WIDTH + PANEL_GAP + SETTINGS_PANEL
      : railPage && tools.activeTool() === null
        ? COMPACT_WIDTH
        : effectiveWidth(),
  );

  // Dispatch runs untracked and behind a sequence guard. Handlers read the
  // state they mutate (the sidebar shape, the tab projection), so a tracked
  // effect would subscribe to its own writes and re-fire on the same command,
  // which made the collapsed menu's Compact Mode toggle immediately undo
  // itself.
  // Whether the pointer is over the column, for what shows only while it is.
  // Tracked rather than left to :hover, which a move straight onto a page's
  // own view can leave standing; leaving the document or the window losing
  // focus ends it too.
  let pointerIn = $state(false);
  $effect(() => {
    const out = () => (pointerIn = false);
    document.documentElement.addEventListener("mouseleave", out);
    window.addEventListener("blur", out);
    return () => {
      document.documentElement.removeEventListener("mouseleave", out);
      window.removeEventListener("blur", out);
    };
  });

  let handledCommand = 0;
  $effect(() => {
    const command = ui.uiCommand();
    if (command.seq === 0 || command.seq === handledCommand) return;
    handledCommand = command.seq;

    // Changed after this pass rather than inside it, as a click would: a
    // shape changed mid-pass re-renders before the old shape is measured,
    // so nothing could travel from it.
    if (command.id === "sidebar.toggleCompact") queueMicrotask(toggleShape);
  });

  function toggleShape() {
    if (tools.activeTool() !== null) tools.close();
    else toggleMode();
  }
</script>

<aside
  bind:this={aside}
  data-hidden={away || undefined}
  data-peek={(away && peeking) || undefined}
  data-armed={(away && armed) || undefined}
  style:--sidebar-frost={away ? `url("${FROSTS[scene()]}")` : undefined}
  data-tauri-drag-region="deep"
  aria-label={m.ui_browser_sidebar()}
  style:width={`${width}px`}
  style:--sidebar-width={`${width}px`}
  data-menu-material={IS_WINDOWS && !settings ? "opaque" : undefined}
  data-reshaping={reshaping}
  data-sidebar-resize-settling={resizeSettling}
  data-header-fresh={headerFresh}
  data-pointer-in={pointerIn}
  onpointerenter={() => {
    pointerIn = true;
    if (away) clearTimeout(linger);
  }}
  onpointerleave={() => {
    pointerIn = false;
    if (away && peeking) release();
  }}
  class="browser-sidebar relative flex shrink-0 flex-col text-text select-none"
>
  {#if !navigating && !railPage && tools.activeTool() === null}<SidebarResizeHandle
      {width}
      disabled={reshaping || hidden}
    />{/if}
  <!-- Settings stands beside the rail with no head: its panel runs the full
       height and the rail keeps only the lights' row. A tool keeps the head,
       with search and the page's own controls. -->
  {#if !settings}<SidebarHeader
      compact={headerCompact}
      launcher={paneled}
      ontoggle={toggleShape}
      pageControls={!inWork}
    />{/if}
  <div
    bind:this={columns}
    class="sidebar-columns"
    data-glide-host
    data-launch={motion.launchState()}
  >
    {#key compact}<div class="sidebar-browser-column" class:sidebar-tool-rail={paneled}>
        {#if settings && IS_MAC}<div class="sidebar-lights" aria-hidden="true"></div>{/if}
        {@render browserBody(compact)}
        {@render dock(compact)}
      </div>{/key}
    {#if settings}<div class="sidebar-tool-host">
        {@render settingsNavigation()}
      </div>{:else if tools.activeTool() !== null}<div class="sidebar-tool-host">
        {@render toolPanel(tools.activeTool()!)}
      </div>{/if}
  </div>
</aside>

<style>
  /* A panel open in the column (the space switcher, the tray on the address,
     the profile's stack) is the one thing to read: whatever it lies over
     steps back under it, and comes forward again when it closes. */
  :global([data-under-panel]) {
    transition: opacity var(--motion-base) var(--ease-out);
  }

  :global(
    .browser-sidebar:has(.sidebar-softens[data-open="true"])
      [data-under-panel]:not(:has(.sidebar-softens[data-open="true"]))
  ) {
    opacity: 0.18;
  }

  @media (prefers-reduced-motion: reduce) {
    :global([data-under-panel]) {
      transition: none;
    }
  }

  /* Hidden, the column is a card that waits beside the window and slides
     over the page. It wears the sky's frost, a picture stretched rather than
     a blur drawn, so bringing it out costs one transform. */
  .browser-sidebar[data-hidden] {
    position: absolute;
    inset-block: 8px;
    inset-inline-start: 8px;
    z-index: 30;

    /* The window's own gutter stands round the column when it is in view;
       out over the page, the card keeps that room inside its edge. */
    box-sizing: content-box;
    padding-inline: 8px;
    padding-block-end: 8px;
    border-radius: var(--content-radius);
    background: var(--sidebar-frost) center / cover;
    box-shadow: var(--shadow-overlay);
    translate: calc(-100% - 24px) 0;
  }

  .browser-sidebar[data-hidden][data-armed] {
    transition: translate var(--motion-page) var(--ease-emphasized);
  }

  .browser-sidebar[data-hidden][data-peek] {
    translate: 0 0;
  }

  @media (prefers-reduced-motion: reduce) {
    .browser-sidebar[data-hidden][data-armed] {
      transition: none;
    }
  }
</style>
