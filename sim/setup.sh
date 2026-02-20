#!/bin/bash
# Setup script for VUnit + OSVVM simulation environment
#
# Run once after cloning the repository:
#   cd sim && ./setup.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Setting up OSVVM ==="

if [ -d "osvvm" ]; then
    echo "OSVVM directory already exists. Updating..."
    cd osvvm
    git pull --recurse-submodules
    cd ..
else
    echo "Cloning OSVVM Libraries..."
    git clone --recursive https://github.com/OSVVM/OsvvmLibraries.git osvvm
fi

echo ""
echo "=== Checking dependencies ==="

# Check for GHDL
if command -v ghdl &> /dev/null; then
    echo "GHDL: $(ghdl --version | head -1)"
else
    echo "WARNING: GHDL not found. Install with:"
    echo "  Ubuntu/Debian: sudo apt install ghdl"
    echo "  Arch: sudo pacman -S ghdl"
    echo "  macOS: brew install ghdl"
fi

# Check for Python and VUnit
if command -v python3 &> /dev/null; then
    echo "Python: $(python3 --version)"
    if python3 -c "import vunit" 2>/dev/null; then
        echo "VUnit: $(python3 -c 'import vunit; print(vunit.__version__)')"
    else
        echo "WARNING: VUnit not found. Install with:"
        echo "  pip install vunit_hdl"
    fi
else
    echo "WARNING: Python 3 not found"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Run tests with:"
echo "  cd sim"
echo "  python run.py        # Run all tests"
echo "  python run.py -v     # Verbose output"
echo "  python run.py --list # List available tests"
echo ""
