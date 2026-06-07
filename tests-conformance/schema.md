# Test Case Schema

Test cases are defined in JSON format.

## General Structure

```json
{
  "id": "unique-test-id",
  "description": "Optional description of what is being tested",
  "input": {
    // Test-suite specific input fields
    // Often contains "file" referring to a relative path to a vector
  },
  "expected": {
    "result": "accept" | "reject",
    "error": "Optional expected error code (if result is reject)"
  }
}
```
