import sys


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "convert":
        from .cli import run

        return run(sys.argv[2:])
    from .gui import run

    return run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
