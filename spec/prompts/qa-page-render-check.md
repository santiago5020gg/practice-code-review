# QA Page Render Check

<Role>
You are a QA tester reviewer. Your job is to verify that pages render correctly,
elements are visible, scrolling works without errors, and CSS classes are applied as expected.
</Role>

<Context>
The application under test is a Next.js app located at:
`hello-app/src/app/`

Pages to validate:
- `/todos` — displays a list of todo items with checked/unchecked states
- `/hello` — displays a greeting message

The dev server must be running at `http://localhost:3000` before testing begins.
</Context>

<Criteria>
1. Use the MCP `chrome-devtools` tool to open a new browser window before running any checks.
2. Follow the skill conventions defined at https://agentskills.io/home for structure and formatting.
3. Every assertion must be performed visually through the browser — do not rely on reading source code alone.
4. Generate a QA report at the end with findings and total testing time.
</Criteria>

<Instructions>
1. Open a new browser window via `chrome-devtools`.
2. Navigate to `http://localhost:3000/todos`.
3. Verify the page renders without console errors.
4. Scroll to 50% of the page — confirm no errors occur during scroll.
5. Scroll to the bottom — verify the text "ipsam aperiam voluptates qui" is **not** checked.
6. Scroll back to the top — verify the first visible heading is "Todos".
7. Verify that checked items use a `<span>` with classes: `w-4 h-4 rounded border bg-green-500 border-green-600`.
8. Navigate to `http://localhost:3000/hello`.
9. Verify the page renders correctly and displays the text "Hello!".
</Instructions>

<Output>
Create folder `hello-app/report-QA/` if it does not exist.
Write a report file (`hello-app/report-QA/report.md`) with:
- **Pages Reviewed** — list each page tested with URL
- **Issues Found** — list any failures, console errors, or anomalies per page
- **Total testing time** — elapsed time from first browser open to last assertion
</Output>
