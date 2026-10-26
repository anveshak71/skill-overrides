---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADR's and glossary) as we go.
disable-model-invocation: true
---

1. Call the Skill tool twice, for "grilling" and "domain-modeling".
2. After grilling and domain-modeling, do not immediately make code changes. Instead, ask the user how to proceed:
   - **Direct Implementation**: Call the Skill tool with "implement" (`/implement`) to implement changes directly.
   - **Spec & Single Ticket**: Call the Skill tool with "to-spec" (`/to-spec`), then call the Skill tool with "to-tickets" (`/to-tickets`) with argument `1 ticket`.
   - **Spec & Multiple Tickets**: Call the Skill tool with "to-spec" (`/to-spec`), then call the Skill tool with "to-tickets" (`/to-tickets`) (forwarding `<count> tickets` if specified, or letting `to-tickets` propose the breakdown).
   - **Other**: Follow the user's custom suggestion or guidance.
3. For ticket workflows, present the published tickets to the user and stop. Do not begin implementation.
