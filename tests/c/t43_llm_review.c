// Advisory escape hatch: a freeform note telling the AI reviewer what to verify
// for code the deterministic engine cannot reason about (`@llm`).
// @llm verify this hand-rolled refcount stays atomic under concurrent release   //EXPECT LLM_REVIEW
void release_ref(void);
