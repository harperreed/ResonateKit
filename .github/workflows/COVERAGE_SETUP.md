# Test Coverage Setup Guide

This document explains how to set up automated test coverage reporting for this repository.

## GitHub Actions Workflow

The repository includes a GitHub Actions workflow (`.github/workflows/tests.yml`) that:

1. ✅ Runs all tests on every push and pull request
2. ✅ Generates code coverage reports
3. ✅ Posts coverage summaries to pull requests
4. ✅ Uploads coverage data to Codecov
5. ✅ Enforces minimum coverage threshold (80%)
6. ✅ Runs integration tests when server is available

## Setup Steps

### 1. Enable GitHub Actions

GitHub Actions should work automatically for this repository. The workflow runs on:
- Pushes to `main` or `develop` branches
- Pull requests targeting `main` or `develop`
- Manual workflow dispatch

### 2. Configure Codecov (Optional)

For advanced coverage tracking and badges:

1. Go to [codecov.io](https://codecov.io)
2. Sign in with your GitHub account
3. Add your repository
4. Get your Codecov token
5. Add it as a repository secret:
   - Go to **Settings** → **Secrets and variables** → **Actions**
   - Click **New repository secret**
   - Name: `CODECOV_TOKEN`
   - Value: Your Codecov token

### 3. Configure Integration Test Server (Optional)

For integration tests against a real Music Assistant server:

1. Add repository secrets:
   - `MA_TEST_HOST`: Your server hostname (e.g., `192.168.1.100`)
   - `MA_TEST_PORT`: Your server port (e.g., `8095`)

2. Integration tests will:
   - Run automatically if secrets are set
   - Skip gracefully if server is unavailable
   - Default to `localhost:8095` if not configured

## Workflow Features

### Coverage Report Generation

The workflow generates coverage using Swift's built-in coverage tools:

```yaml
swift test --enable-code-coverage
```

Coverage is exported in LCOV format for compatibility with various tools.

### Pull Request Comments

On every PR, the workflow posts a comment with:
- Overall coverage percentage
- Detailed coverage report by file
- Comparison to previous coverage (when using Codecov)

Example comment:
```markdown
## 📊 Test Coverage Report

**Overall Coverage: 85.3%**

<details>
<summary>Detailed Coverage Report</summary>

[Coverage details here]

</details>
```

### Coverage Threshold

The workflow enforces a minimum **80% coverage threshold**. Builds fail if coverage drops below this level.

To adjust the threshold, edit `.github/workflows/tests.yml`:

```yaml
THRESHOLD=80  # Change this value
```

### Artifacts

Coverage reports are uploaded as workflow artifacts and retained for 30 days:
- `coverage.lcov` - LCOV format for external tools
- `coverage-report.txt` - Human-readable text report

## Running Coverage Locally

### Generate Coverage Report

```bash
# Run tests with coverage
swift test --enable-code-coverage

# Generate LCOV report
xcrun llvm-cov export \
  -format="lcov" \
  .build/debug/MusicAssistantKitPackageTests.xctest/Contents/MacOS/MusicAssistantKitPackageTests \
  -instr-profile .build/debug/codecov/default.profdata \
  > coverage.lcov

# Generate text report
xcrun llvm-cov report \
  .build/debug/MusicAssistantKitPackageTests.xctest/Contents/MacOS/MusicAssistantKitPackageTests \
  -instr-profile .build/debug/codecov/default.profdata
```

### View Coverage in Xcode

1. Run tests: `⌘U`
2. Open the **Report Navigator** (⌘9)
3. Select the test run
4. Click the **Coverage** tab
5. Explore line-by-line coverage

### HTML Coverage Report

For a browsable HTML report:

```bash
xcrun llvm-cov show \
  .build/debug/MusicAssistantKitPackageTests.xctest/Contents/MacOS/MusicAssistantKitPackageTests \
  -instr-profile .build/debug/codecov/default.profdata \
  -format=html \
  -output-dir=coverage-html

# Open in browser
open coverage-html/index.html
```

## Adding a Coverage Badge

### Using Codecov

Once Codecov is configured, add this badge to your README:

```markdown
[![codecov](https://codecov.io/gh/YOUR_USERNAME/YOUR_REPO/branch/main/graph/badge.svg)](https://codecov.io/gh/YOUR_USERNAME/YOUR_REPO)
```

### Using Shields.io

For a custom badge without Codecov:

```markdown
![Coverage](https://img.shields.io/badge/coverage-85%25-brightgreen)
```

## Troubleshooting

### Coverage Report Not Generated

**Issue:** `xcrun llvm-cov` fails to find test binary

**Solution:** Ensure tests ran successfully first:
```bash
swift test --enable-code-coverage
```

### Coverage Too Low

**Issue:** Coverage below 80% threshold

**Solutions:**
1. Add missing unit tests (see `TEST_COVERAGE.md`)
2. Test edge cases and error paths
3. Review untested code in coverage report

### Integration Tests Fail

**Issue:** Integration tests fail in CI

**Solutions:**
1. Check if `MA_TEST_HOST` and `MA_TEST_PORT` secrets are set
2. Verify server is accessible from GitHub Actions runners
3. Consider running integration tests separately or on-demand

## Best Practices

1. **Run coverage locally before pushing**
   ```bash
   swift test --enable-code-coverage
   ```

2. **Review coverage trends** - Use Codecov graphs to track coverage over time

3. **Aim for >80% coverage** - But focus on testing critical paths, not just hitting numbers

4. **Test behavior, not implementation** - Good tests survive refactoring

5. **Update tests when changing code** - Keep tests in sync with implementation

## Customization

### Change Xcode Version

Edit `.github/workflows/tests.yml`:

```yaml
- name: Select Xcode version
  run: sudo xcode-select -s /Applications/Xcode_16.0.app/Contents/Developer
```

### Run Different Test Suites

```yaml
# Unit tests only
swift test --filter "Unit Tests"

# Integration tests only
swift test --filter "Integration Tests"

# Specific suite
swift test --filter ConnectionStateTests
```

### Skip Coverage Threshold Check

Comment out or remove this step in `tests.yml`:

```yaml
# - name: Check coverage threshold
#   run: |
#     # ... coverage check code
```

## Resources

- [Swift Package Manager Testing](https://github.com/apple/swift-package-manager/blob/main/Documentation/Usage.md#testing)
- [Swift Testing Framework](https://github.com/apple/swift-testing)
- [Codecov Documentation](https://docs.codecov.com/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
