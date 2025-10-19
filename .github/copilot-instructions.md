When working on the Elba programming language:

- Be sure to only add features or workings that are added in proposals

1. When testing changes or features, you can either:
    - Create new elba files, then delete it after testing.
    - Or, use a single elba file for everything.

2. When building:
    - Use `zig build` to compile the project.
    - Use `zig build run <file>` to run a specific elba file. (Additionally, you can use `./zig-out/bin/elba.exe <file>` to run it directly.)

3. When editing:
    - Ensure your code adheres to the project's coding style and conventions.
    - Write clear and concise comments to explain complex logic.
    - Make sure memory management is handled properly to avoid leaks.
    - Errors are handled gracefully with informative messages.
    - Follow Zig's best practices for performance and safety.
    - Make sure texts are UTF-8 Encoded only.

4. When finalizing changes:
    - Test thoroughly to ensure new features work as intended and do not introduce bugs.
    - Review code for readability and maintainability.
    - Do not create documentations or test files unless explicitly instructed.
    - Remove any temp tests files if they were made.
    - Only create summaries on the chat.