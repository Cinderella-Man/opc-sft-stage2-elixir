Given the following JSON:

```json id="x91k2p"
<PASTE JSON HERE>
```

The JSON contains:

* `instruction`
* `elixir_code`
* `original_instruction` (Python version)
* `python_code`

Analyze the Elixir implementation in relation to the Python reference.

Respond in three sections:

---

### 1. Reformatted Elixir Code

* Present the `elixir_code` value properly formatted using idiomatic Elixir style.
* Do not change the logic.

---

### 2. Issues with Instruction

* List only problems, ambiguities, or weaknesses in the `instruction` field.
* Do NOT include any positive feedback.
* For each issue:

  * Provide a brief explanation
  * Suggest an improvement (if possible)
  * Compare against `original_instruction` when relevant, using explicit statements such as:

    * “This issue also exists in the Python instruction”
    * “This is handled in the Python instruction but missing here”
    * “This differs from the Python instruction in the following way: …”

---

### 3. Issues with Elixir Code

* List only problems, non-idiomatic patterns, incorrect logic, or performance concerns.

* Do NOT include any positive feedback.

* Explicitly consider:

  * Idiomatic Elixir practices
  * Readability and maintainability
  * Performance (time and space complexity, unnecessary work, inefficiencies)

* For each issue:

  * Provide a brief explanation
  * Suggest a fix (if possible)
  * Compare against `python_code` when relevant, using explicit statements such as:

    * “The Python implementation has the same issue”
    * “The Python version handles this case correctly, but the Elixir version does not”
    * “This behavior differs from the Python version: …”

---

### General requirements

* Prefer precise, concrete observations over vague statements.
* Do not invent differences—only compare when there is a clear, relevant relationship.
* Keep comparisons concise and directly tied to the issue being described.
* **Fail-fast behavior is acceptable**: If the Elixir code crashes or raises due to unexpected input, this should NOT be considered a problem **as long as the input violates the `instruction`/@spec and the spec is clearly defined and strict**. Only flag it as an issue if:

  * The instruction/spec is ambiguous or underspecified, or
  * The behavior contradicts the intended contract, or
  * The Python version handles the same case more explicitly or safely in a way that suggests a mismatch in expectations.