"""Entry point used by the app: python3 -B -s -E run_brain.py --socket <path>."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from photolab_brain.server import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
