/**
 * Adds questions to a running client-side booth without reloading the page.
 *
 * In a `per_question` election the admin opens questions one by one while
 * voters wait. Reloading the booth would drop whatever session the voting
 * backend's adapter keeps in page memory (a census token, for instance) and
 * make the voter identify again for every question. Instead, the adapter asks
 * the booth to fetch its own page again and import the question sections this
 * page lacks, so the markup is still the server's.
 */

/**
 * Fetches the booth page and appends to `form` the question sections whose
 * `data-question-id` is not among `questions`.
 *
 * @param {Object} options - what to fetch and where to put it.
 * @param {string} options.url - the booth page. Redirects are followed, so a
 *   URL that no longer leads to a booth (nothing left open) yields null.
 * @param {HTMLElement} options.form - the `[data-booth-form]` element.
 * @param {HTMLElement[]} options.questions - sections already on the page.
 * @returns {Promise<{sections: HTMLElement[], config: Object}|null>} the added
 *   sections and the page's booth config, or null without a booth.
 */
export const fetchBoothQuestions = async ({ url, form, questions }) => {
  const response = await fetch(url, { credentials: "same-origin", headers: { Accept: "text/html" } });
  if (!response.ok) {
    return null;
  }

  const page = new DOMParser().parseFromString(await response.text(), "text/html");
  const root = page.querySelector("[data-voting-booth]");
  if (!root) {
    return null;
  }

  const rendered = new Set(questions.map((section) => section.dataset.questionId));
  const sections = Array.from(root.querySelectorAll("[data-booth-question]")).
    filter((section) => !rendered.has(section.dataset.questionId)).
    map((section) => document.importNode(section, true));
  form.append(...sections);

  return { sections, config: JSON.parse(root.dataset.config || "{}") };
};

/**
 * Builds `ctx.loadQuestions` for one booth.
 *
 * @param {Object} options - the booth's state.
 * @param {HTMLElement} options.form - the `[data-booth-form]` element.
 * @param {HTMLElement[]} options.questions - the booth's sections; new ones
 *   are pushed onto this same array.
 * @param {Function} options.onAdded - wires up the added sections.
 * @returns {Function} `(url?) => Promise<{questionIds, config}|null>`: the
 *   added question ids and the freshly rendered config, or null when the URL
 *   no longer leads to a booth.
 */
export const createQuestionLoader = ({ form, questions, onAdded }) => async (url) => {
  const loaded = await fetchBoothQuestions({ url: url || window.location.href, form, questions });
  if (!loaded) {
    return null;
  }
  questions.push(...loaded.sections);
  onAdded(loaded.sections);

  return { questionIds: loaded.sections.map((section) => section.dataset.questionId), config: loaded.config };
};
