#!/usr/bin/env python3
"""
VUnit test runner for vga_dma with OSVVM AXI4 verification components.

Usage:
    python run.py                    # Run all tests
    python run.py -v                 # Verbose output
    python run.py --list             # List available tests
    python run.py *burst*            # Run tests matching pattern
    python run.py --gui              # Open waveform viewer after run
    python run.py -p 4               # Run 4 tests in parallel

Setup (run once):
    cd sim
    git clone --recursive https://github.com/OSVVM/OsvvmLibraries.git osvvm
"""

from pathlib import Path
import subprocess
from vunit import VUnit

ROOT = Path(__file__).parent.parent
SIM_DIR = Path(__file__).parent

# Create VUnit instance with GHDL
vu = VUnit.from_argv(compile_builtins=False)
vu.add_vhdl_builtins()

def ghdl_std_flag():
    """
    Select the newest supported VHDL standard for this GHDL installation.
    Ubuntu's ghdl-mcode package often ships only up to v08 precompiled libs.
    """
    try:
        result = subprocess.run(
            ["ghdl", "--dispconfig"],
            check=False,
            capture_output=True,
            text=True,
        )
        library_prefix = None
        for line in result.stdout.splitlines():
            if line.startswith("library prefix:"):
                library_prefix = line.split(":", 1)[1].strip()
                break
        if library_prefix:
            lib_path = Path(library_prefix)
            if (lib_path / "ieee" / "v19").exists() and (lib_path / "std" / "v19").exists():
                return "--std=19"
    except Exception:
        pass
    return "--std=08"


selected_std = ghdl_std_flag()

# GHDL compile options for OSVVM and DUT.
ghdl_flags = [selected_std, "-frelaxed-rules", "-fsynopsys"]

# ============================================================================
# OSVVM Libraries
# ============================================================================
osvvm_path = SIM_DIR / "osvvm"

if not (osvvm_path / "osvvm").exists():
    print("=" * 60)
    print("OSVVM not found. Please run:")
    print(f"  cd {SIM_DIR}")
    print("  git clone --recursive https://github.com/OSVVM/OsvvmLibraries.git osvvm")
    print("=" * 60)
    exit(1)

# OSVVM core library - exclude vendor-specific files (use default only)
osvvm_lib = vu.add_library("osvvm")
osvvm_core_path = osvvm_path / "osvvm"

# For tools limited to VHDL-2008, OSVVM provides compatibility shims.
compat_replacements = {}
if selected_std != "--std=19":
    compat_replacements = {
        "FileLinePathPkg.vhd": osvvm_core_path / "deprecated" / "FileLinePathPkg_c.vhd",
        "LanguageSupport2019Pkg.vhd": osvvm_core_path / "deprecated" / "LanguageSupport2019Pkg_c.vhd",
        "RandomPkg2019.vhd": osvvm_core_path / "deprecated" / "RandomPkg2019_c.vhd",
    }

for f in sorted(osvvm_core_path.glob("*.vhd")):
    # Skip vendor-specific implementations (Aldec, NVC, etc.) - use default
    if "_Aldec" in f.name or "_NVC" in f.name or "_Mentor" in f.name:
        continue
    osvvm_lib.add_source_files(compat_replacements.get(f.name, f))

# OSVVM Common library (required by AXI4)
osvvm_common_lib = vu.add_library("osvvm_common")
osvvm_common_lib.add_source_files(osvvm_path / "Common" / "src" / "*.vhd")

# OSVVM AXI4 library
osvvm_axi4_lib = vu.add_library("osvvm_axi4")
osvvm_axi4_lib.add_source_files(osvvm_path / "AXI4" / "common" / "src" / "*.vhd")
osvvm_axi4_lib.add_source_files(osvvm_path / "AXI4" / "Axi4" / "src" / "*.vhd")

# ============================================================================
# Design Under Test
# ============================================================================
dut_lib = vu.add_library("dut_lib")

# DUT
dut_lib.add_source_files(ROOT / "rtl" / "vga" / "vga_dma.vhd")
dut_lib.add_source_files(ROOT / "rtl" / "vga" / "vga_controller.vhd")

# Testbenches
dut_lib.add_source_files(SIM_DIR / "tb_*.vhd")

# ============================================================================
# Compile and Simulation Options (must be set AFTER adding sources)
# ============================================================================
# Apply GHDL flags to all libraries
for lib in [osvvm_lib, osvvm_common_lib, osvvm_axi4_lib, dut_lib]:
    lib.set_compile_option("ghdl.a_flags", ghdl_flags)

# Set simulation flags for test benches
vu.set_sim_option("ghdl.elab_flags", ghdl_flags + ["--syn-binding"])

# Add waveform generation for debugging (optional, slows simulation)
vu.set_sim_option("ghdl.sim_flags", ["--wave=waves.ghw"])

# ============================================================================
# Parameterized burst-length configurations for VGA DMA testbench
# ============================================================================
tb_dma_burst = dut_lib.test_bench("tb_vga_dma_burst")
for beats in [16, 32, 64]:
    tb_dma_burst.add_config(name=f"burst_{beats}", generics={"BURST_BEATS": beats})

vu.main()
