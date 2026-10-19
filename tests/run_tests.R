# Run the whole test suite. Run it from the project root (/app in the dev
# image), inside the dev container, never on the bare host:
#
#   docker compose -f docker-compose.dev.yml run --rm app Rscript tests/run_tests.R
#
# Exits with a non-zero status if any test fails, so CI can rely on it.

testthat::test_dir("tests/testthat", stop_on_failure = TRUE)
