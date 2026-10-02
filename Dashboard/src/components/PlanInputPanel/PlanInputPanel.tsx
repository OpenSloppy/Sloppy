import { useMemo, useState } from "react";
import { collectPlanInputAnswers, hasPlanInputAnswer } from "./planInputAnswers";
import "./PlanInputPanel.css";

type PlanInputOption = {
  id?: string;
  label?: string;
  description?: string;
};

type PlanInputQuestion = {
  id?: string;
  header?: string;
  question?: string;
  options?: PlanInputOption[];
  allowCustomAnswer?: boolean;
};

type PlanInputRequest = {
  id?: string;
  mode?: string;
  title?: string;
  questions?: PlanInputQuestion[];
  autoApproveAt?: string;
};

type PlanInputPanelProps = {
  request: PlanInputRequest;
  disabled?: boolean;
  onSubmit: (payload: Record<string, unknown>) => Promise<void> | void;
};

export function PlanInputPanel({ request, disabled = false, onSubmit }: PlanInputPanelProps) {
  const questions = useMemo(
    () => (Array.isArray(request?.questions) ? request.questions : []).filter((q) => String(q?.id || "").trim()),
    [request]
  );
  const debugQuestion = questions.length === 1 && request?.mode === "debug" ? questions[0] : null;
  const isDebugActionRequest = Boolean(
    debugQuestion
      && Array.isArray(debugQuestion.options)
      && ["proceed", "bug_repeated", "mark_as_fixed"].every((id) => debugQuestion.options?.some((option) => option.id === id))
  );
  const [selectedByQuestion, setSelectedByQuestion] = useState<Record<string, string>>({});
  const [customByQuestion, setCustomByQuestion] = useState<Record<string, string>>({});
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [errorText, setErrorText] = useState("");
  const [activeQuestionIndex, setActiveQuestionIndex] = useState(0);
  const activeQuestion = questions[activeQuestionIndex];

  function advance() {
    if (!activeQuestion || isSubmitting || disabled) return;
    const questionId = String(activeQuestion.id || "");
    if (!hasPlanInputAnswer(questionId, selectedByQuestion, customByQuestion)) {
      setErrorText("Choose an option or enter a custom answer.");
      return;
    }
    setErrorText("");
    if (activeQuestionIndex < questions.length - 1) {
      setActiveQuestionIndex((index) => index + 1);
    } else {
      void submit("answered");
    }
  }

  async function submit(status: "answered" | "cancelled") {
    if (isSubmitting || disabled) return;
    setErrorText("");
    const answers = status === "cancelled"
      ? []
      : collectPlanInputAnswers(questions, selectedByQuestion, customByQuestion);
    if (status === "answered" && answers.some((answer) => !answer.selectedOptionId && !answer.customAnswer)) {
      setErrorText("Answer every question before submitting.");
      return;
    }
    setIsSubmitting(true);
    try {
      await onSubmit({
        status,
        userId: "dashboard",
        answers
      });
    } catch {
      setErrorText("Could not submit answers.");
    } finally {
      setIsSubmitting(false);
    }
  }

  async function submitDebugOption(questionId: string, optionId: string) {
    if (isSubmitting || disabled) return;
    setErrorText("");
    setIsSubmitting(true);
    try {
      await onSubmit({
        status: "answered",
        userId: "dashboard",
        answers: [{ questionId, selectedOptionId: optionId }]
      });
    } catch {
      setErrorText("Could not submit answer.");
    } finally {
      setIsSubmitting(false);
    }
  }

  if (isDebugActionRequest && debugQuestion) {
    const questionId = String(debugQuestion.id || "");
    const orderedOptions = ["proceed", "bug_repeated", "mark_as_fixed"]
      .map((id) => debugQuestion.options?.find((option) => option.id === id))
      .filter(Boolean) as PlanInputOption[];
    return (
      <section className="plan-input-panel plan-input-panel--debug" aria-label="Debug input request">
        <div className="plan-input-panel__head">
          <span className="material-symbols-rounded" aria-hidden="true">bug_report</span>
          <strong>{request.title || "Debug checkpoint"}</strong>
        </div>
        {request.autoApproveAt ? <p className="placeholder-text">If you do not answer within 2 minutes, the agent will decide and continue.</p> : null}
        <div className="plan-input-panel__question">
          {debugQuestion.header ? <span className="plan-input-panel__header">{debugQuestion.header}</span> : null}
          <p>{debugQuestion.question}</p>
          <div className="plan-input-panel__debug-actions">
            {orderedOptions.map((option) => (
              <button
                key={option.id}
                type="button"
                className={`btn btn-sm ${option.id === "mark_as_fixed" ? "btn-secondary" : "btn-primary"}`}
                disabled={disabled || isSubmitting}
                onClick={() => void submitDebugOption(questionId, String(option.id || ""))}
                title={option.description || option.label || option.id}
              >
                {option.label || option.id}
              </button>
            ))}
          </div>
        </div>
        {errorText ? <p className="plan-input-panel__error">{errorText}</p> : null}
      </section>
    );
  }

  return (
    <section className="plan-input-panel" aria-label="Plan input request">
      <div className="plan-input-panel__head">
        <span className="material-symbols-rounded" aria-hidden="true">help</span>
        <strong>{request.title || "Input needed"}</strong>
        {questions.length > 1 ? <span className="plan-input-panel__progress">Question {activeQuestionIndex + 1} of {questions.length}</span> : null}
      </div>
      {request.autoApproveAt ? <p className="placeholder-text">If you do not answer within 2 minutes, the agent will decide and continue.</p> : null}
      {activeQuestion ? [activeQuestion].map((question) => {
        const questionId = String(question.id || "");
        const options = Array.isArray(question.options) ? question.options : [];
        return (
          <div key={questionId} className="plan-input-panel__question">
            {question.header ? <span className="plan-input-panel__header">{question.header}</span> : null}
            <p>{question.question}</p>
            <div className="plan-input-panel__options">
              {options.map((option) => {
                const optionId = String(option.id || "");
                return (
                  <label key={optionId} className="plan-input-panel__option">
                    <input
                      type="radio"
                      name={`plan-input-${request.id}-${questionId}`}
                      checked={selectedByQuestion[questionId] === optionId && !customByQuestion[questionId]}
                      disabled={disabled || isSubmitting}
                      onChange={() => {
                        setSelectedByQuestion((current) => ({ ...current, [questionId]: optionId }));
                        setCustomByQuestion((current) => ({ ...current, [questionId]: "" }));
                      }}
                    />
                    <span>
                      <strong>{option.label || optionId}</strong>
                      {option.description ? <small>{option.description}</small> : null}
                    </span>
                  </label>
                );
              })}
            </div>
            {question.allowCustomAnswer !== false ? (
              <input
                className="plan-input-panel__custom"
                type="text"
                value={customByQuestion[questionId] || ""}
                disabled={disabled || isSubmitting}
                placeholder="Custom answer"
                onChange={(event) => {
                  const value = event.target.value;
                  setCustomByQuestion((current) => ({ ...current, [questionId]: value }));
                  if (value.trim()) {
                    setSelectedByQuestion((current) => ({ ...current, [questionId]: "" }));
                  }
                }}
              />
            ) : null}
          </div>
        );
      }) : null}
      {errorText ? <p className="plan-input-panel__error">{errorText}</p> : null}
      <div className="plan-input-panel__actions">
        <button type="button" className="btn btn-secondary btn-sm" disabled={disabled || isSubmitting} onClick={() => void submit("cancelled")}>
          Cancel
        </button>
        {activeQuestionIndex > 0 ? (
          <button type="button" className="btn btn-secondary btn-sm" disabled={disabled || isSubmitting} onClick={() => { setErrorText(""); setActiveQuestionIndex((index) => index - 1); }}>
            Back
          </button>
        ) : null}
        <button type="button" className="btn btn-primary btn-sm" disabled={disabled || isSubmitting || !activeQuestion} onClick={advance}>
          {activeQuestionIndex < questions.length - 1 ? "Next" : "Submit all answers"}
        </button>
      </div>
    </section>
  );
}
