/**
 * Receipt extras of the client-side booth: the waiting panel shown while the
 * next per-question question is still closed, and the "already recorded"
 * banner shown when a partial ballot is resumed.
 *
 * @param {Object} options - booth elements and helpers.
 * @param {HTMLElement} options.receipt - the receipt step.
 * @param {HTMLElement|null} options.banner - the `[data-booth-already-recorded]` callout.
 * @param {Function} options.progress - sets the booth status line.
 * @param {Object} options.i18n - booth texts.
 * @returns {Object} controls used by `booth.js`.
 */
export const createReceiptPanels = ({ receipt, banner, progress, i18n }) => {
  const panel = receipt && receipt.querySelector("[data-booth-waiting]");
  const header = receipt && receipt.querySelector("[data-booth-receipt-header]");

  const toggle = (on) => {
    if (panel) {
      panel.hidden = !on;
    }
    if (header) {
      header.hidden = on;
    }
  };

  const hideBanner = ({ clear = false } = {}) => {
    if (!banner) {
      return;
    }
    banner.hidden = true;
    if (clear) {
      banner.replaceChildren();
    }
  };

  const showBanner = () => {
    if (!banner) {
      return;
    }
    const texts = i18n.already_recorded || {};
    const heading = document.createElement("h4");
    heading.className = "font-semibold";
    heading.textContent = texts.title || "";
    const body = document.createElement("p");
    body.textContent = texts.body || "";
    banner.replaceChildren(heading, body);
    banner.hidden = false;
  };

  // Adapter hook: the panel on the receipt step, the status line on any other step.
  const waiting = (on) => {
    if (!panel) {
      return;
    }
    if (receipt.hidden) {
      progress(on && i18n.waiting
        ? i18n.waiting.title
        : "");
      return;
    }
    toggle(on);
    if (on) {
      progress("");
    }
  };

  // Leaving the receipt step hides the panel and restores the success header.
  const leave = () => toggle(false);

  return { waiting, leave, showBanner, hideBanner };
};
