/* global jest */
import { createQuestionLoader, fetchBoothQuestions } from "src/decidim/elections/booth_live";

const section = (id) => `
  <section data-booth-step="question" data-booth-question data-question-id="${id}" data-question-title="Q${id}" hidden>
    <button type="button" data-booth-back>back</button>
    <button type="button" data-booth-next>next</button>
  </section>`;

const boothPage = (ids, config = {}) => `
  <html><body>
    <div data-voting-booth data-config='${JSON.stringify(config)}'>
      <form data-booth-form>${ids.map(section).join("")}</form>
    </div>
  </body></html>`;

const respond = (body, ok = true) => {
  window.fetch = jest.fn().mockResolvedValue({ ok, text: () => Promise.resolve(body) });
};

const setUp = (ids) => {
  document.body.innerHTML = `<form data-booth-form>${ids.map(section).join("")}</form>`;
  const form = document.querySelector("[data-booth-form]");

  return { form, questions: Array.from(form.querySelectorAll("[data-booth-question]")) };
};

describe("fetchBoothQuestions", () => {
  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  it("appends only the questions the page lacks and returns the page's config", async () => {
    const { form, questions } = setUp(["1"]);
    respond(boothPage(["1", "2"], { questions: [{ questionId: "1" }, { questionId: "2" }] }));

    const loaded = await fetchBoothQuestions({ url: "/booth", form, questions });

    expect(window.fetch).toHaveBeenCalledWith("/booth", expect.objectContaining({ credentials: "same-origin" }));
    expect(loaded.sections.map((sect) => sect.dataset.questionId)).toEqual(["2"]);
    expect(loaded.config.questions).toHaveLength(2);
    expect(Array.from(form.querySelectorAll("[data-booth-question]")).map((sect) => sect.dataset.questionId)).toEqual(["1", "2"]);
  });

  it("returns null when the URL no longer leads to a booth", async () => {
    const { form, questions } = setUp(["1"]);
    respond("<html><body><p>Waiting for the next question</p></body></html>");

    expect(await fetchBoothQuestions({ url: "/booth", form, questions })).toBeNull();
    expect(form.querySelectorAll("[data-booth-question]")).toHaveLength(1);
  });

  it("returns null on an error response", async () => {
    const { form, questions } = setUp(["1"]);
    respond("", false);

    expect(await fetchBoothQuestions({ url: "/booth", form, questions })).toBeNull();
  });
});

describe("createQuestionLoader", () => {
  afterEach(() => {
    Reflect.deleteProperty(window, "fetch");
  });

  it("grows the booth's question list and wires up the new sections", async () => {
    const { form, questions } = setUp(["1"]);
    const onAdded = jest.fn();
    respond(boothPage(["1", "2", "3"], { perQuestion: true }));

    const result = await createQuestionLoader({ form, questions, onAdded })("/booth");

    expect(result).toEqual({ questionIds: ["2", "3"], config: { perQuestion: true } });
    expect(questions.map((sect) => sect.dataset.questionId)).toEqual(["1", "2", "3"]);
    expect(onAdded).toHaveBeenCalledWith(questions.slice(1));
  });

  it("leaves the booth alone when there is no booth to load", async () => {
    const { form, questions } = setUp(["1"]);
    const onAdded = jest.fn();
    respond("<html><body></body></html>");

    expect(await createQuestionLoader({ form, questions, onAdded })("/booth")).toBeNull();
    expect(questions).toHaveLength(1);
    expect(onAdded).not.toHaveBeenCalled();
  });
});
