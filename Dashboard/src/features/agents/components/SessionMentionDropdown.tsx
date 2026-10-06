import React from "react";
import type { MentionSuggestion } from "../sessionMentions";
import "../sessionMentions.css";

export function SessionMentionDropdown({ suggestions, activeIndex, loading, failed, onSelect }: {
  suggestions: MentionSuggestion[];
  activeIndex: number;
  loading: boolean;
  failed: boolean;
  onSelect: (suggestion: MentionSuggestion) => void;
}) {
  return (
    <div className="actor-team-search session-mention-dropdown" role="listbox" aria-label="Session, file and skill suggestions">
      {loading ? <p role="status">Searching…</p> : null}
      {failed ? <p role="status">Session search unavailable. Type @ to retry.</p> : null}
      {!loading && !failed && suggestions.length === 0 ? <p>No matches</p> : null}
      {suggestions.map((suggestion, index) => (
        <React.Fragment key={suggestion.id}>
          {index === 0 || suggestions[index - 1].group !== suggestion.group
            ? <div className="session-mention-group">{suggestion.group}</div> : null}
          <button type="button" role="option" aria-selected={activeIndex === index}
            className={activeIndex === index ? "session-mention-option active" : "session-mention-option"}
            onMouseDown={(event) => event.preventDefault()} onClick={() => onSelect(suggestion)}>
            <span>{suggestion.title}</span><small>{suggestion.subtitle}</small>
          </button>
        </React.Fragment>
      ))}
    </div>
  );
}
