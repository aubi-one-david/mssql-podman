# Contributing

Thanks for your interest in contributing to mssql-podman!

## How to contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run the tests:
   ```bash
   # Unit tests (no container needed)
   python3 -m pytest test_mssql_tray.py -v

   # Integration tests (requires Podman and starts a real container)
   ./test-mssql.sh
   ```
5. Commit your changes (`git commit -m 'Add my feature'`)
6. Push to your fork (`git push origin my-feature`)
7. Open a Pull Request

## Reporting issues

Please open a GitHub issue with:
- A clear description of the problem
- Steps to reproduce
- Your environment (OS, Podman version, Python version)

## Code style

- Shell scripts: follow the existing style in `mssql.sh`
- Python: PEP 8
