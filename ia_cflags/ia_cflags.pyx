#! /usr/bin/env python
# cython: language_level=3
# distutils: language=c++

import ast
from contextlib  import ExitStack, contextmanager
from dataclasses import dataclass
import dis
import hashlib
import importlib
import inspect
from io          import StringIO
import logging
import multiprocessing
import os
from pathlib     import Path
import platform
import re
import shlex
import shutil
import socket
import subprocess
from subprocess  import Popen
import sys
import sysconfig
import time
import tomllib
from types       import *
from typing      import *

#import build
#import git
#import github # FIXME unused ???? !!!!!!! how to create remote repo ?
#import mdutils
#import pipreqs
##import tomli
#import tomli_w

def merge_compiler_flags()->None:
    """
    Parses current and env flags into a key-value map to handle overrides 
    (e.g., -O2 -> -O3) and ensures 'Last-In-Wins' behavior.
    """
    target_keys = ['OPT', 'CFLAGS', 'PY_CFLAGS', 'PY_CORE_CFLAGS', 'CONFIGURE_CFLAGS', 'LDSHARED']
    cvars = sysconfig.get_config_vars()

    def tokenize_to_dict(flag_list):
        """Converts flags into a dict for easy overriding."""
        result = {}
        # We use a placeholder for flags that don't take arguments (like -pipe)
        for f in flag_list:
            if f.startswith('-O'): result['-O'] = f
            elif f.startswith('-march='): result['-march'] = f
            elif f.startswith('-mtune='): result['-mtune'] = f
            elif f.startswith('-g'): result['-g'] = f  # catches -g, -g0, -g3
            else: result[f] = None
        return result

    # 1. Capture Environment Intent
    env_flags = shlex.split(os.environ.get('CFLAGS', ''))
    env_overrides = tokenize_to_dict(env_flags)

    for key in target_keys:
        if key not in cvars: continue
        
        # 2. Tokenize existing Python defaults
        current_flags = shlex.split(cvars[key])
        flag_dict = tokenize_to_dict(current_flags)

        # 3. Apply Overrides (Environment values replace Python defaults)
        flag_dict.update(env_overrides)

        # 4. Reconstruct the string
        # If value is None, it's a standalone flag; otherwise, it's the full string (-O3)
        final_flags = [f if v is None else v for f, v in flag_dict.items()]
        cvars[key] = " ".join(final_flags)

def detect_compiler_type() -> str:
    """
    Detects if the active compiler is 'clang' or 'gcc'.
    Checks env vars first, then sysconfig, then binary help strings.
    """
    # 1. Check environment variables (the standard override)
    cxx = os.environ.get('CXX') or os.environ.get('CC')

    # 2. Fallback to sysconfig (what Python was built with / defaults to)
    if not cxx:
        cxx = sysconfig.get_config_var('CXX') or sysconfig.get_config_var('CC')

    # 3. Default to 'g++' if still nothing
    if not cxx:
        cxx = 'g++'

    # Clean the path (e.g., 'ccache g++' -> 'g++')
    executable = shlex.split(cxx)[0]

    # If the executable isn't in path, we're likely going to fail anyway,
    # but let's assume gcc-like behavior
    if not shutil.which(executable):
        return 'gcc'

    #try:
    if True: # fail fast
        # Ask the compiler who it is.
        # Clang and GCC both support --version, but Clang identifies itself clearly.
        result = subprocess.run([executable, '--version'],
                                capture_output=True, text=True, check=False)
        output = result.stdout.lower() + result.stderr.lower()

        if 'clang' in output or 'apple llvm' in output:
            return 'clang'
        if 'gcc' in output or 'g++' in output:
            return 'gcc'
    #except Exception as e:
    #    pass

    return 'gcc' # Default fallback

def get_cflags(afdo_path:Path|None=None, instrumentation:bool=True, compiler_type:str|None=None, native:bool=True)->List[str]:
    afdo_path                                = afdo_path.resolve() if afdo_path else None # just in case
    compiler_type       :str                 = compiler_type or detect_compiler_type()
    instrumentation_args:Dict[str,List[str]] = {
            'clang': ['-gmlt', '-fdebug-info-for-profiling', ],
            'gcc'  : ['-g1',   '-fno-eliminate-unused-debug-types', ],
    }
    if afdo_path:
        instrumentated_args :Dict[str,List[str]] = {
            'clang': [f'-fprofile-sample-use={afdo_path}', ], # '-Wno-missing-profile'
            'gcc'  : [f'-fauto-profile={afdo_path}', ],
        }
    args                :List[str]           = []
    if native:
        #args.extend(get_arch_flags(compiler_type))
        args.extend(get_best_optimization_flags())
    if instrumentation:
        _args           :List[str]           = instrumentation_args[compiler_type]
        args.extend(_args)
    
    if afdo_path and afdo_path.exists():
        logging.info(f'found profile: {afdo_path}')
        assert afdo_path.is_file()
        _args           :List[str]           = instrumentated_args[compiler_type]
        args.extend(_args)
        return args
    assert not afdo_path or not afdo_path.exists()
    logging.warn(f'no profile: {afdo_path}')
    return args

def get_build_env(afdo_path: Path|None=None) -> Dict[str, str]:
    """
    Merges AFDO flags into existing CFLAGS/CXXFLAGS using shlex to ensure
    proper quoting and to avoid redundant flag spam.
    """
    # 1. Get our desired flags as a list
    new_flags_list         :List[str]     = get_cflags(afdo_path)

    env                    :Dict[str,str] = os.environ.copy()

    for key in ["CFLAGS", "CXXFLAGS"]:
        # 2. Parse existing flags into a list
        existing_val       :str           = env.get(key, "")
        existing_flags_list:List[str]     = shlex.split(existing_val)

        # 3. Merge lists.
        # Using a dict or set logic here ensures 'idempotency' of the flags themselves.
        # We put new_flags_list last so they take precedence if there's a conflict.
        merged_list        :List[str]     = existing_flags_list + [
                f
                for f in new_flags_list
                if f not in existing_flags_list]

        # 4. Join back into a shell-safe string
        env[key]                          = shlex.join(merged_list)

    return env

#def detect_native_arch(compiler_type: str | None = None) -> str:
#    """
#    Asks the compiler what it thinks '-march=native' resolves to.
#    """
#    compiler_type = compiler_type or detect_compiler_type()
#    cxx = shlex.split(os.environ.get('CXX') or 'g++')[0]
#
#    if compiler_type == 'gcc':
#        # GCC: -Q --help=target shows the resolved march
#        cmd = [cxx, '-march=native', '-Q', '--help=target']
#        result = subprocess.run(cmd, capture_output=True, text=True)
#        # Look for the line: "-march=   <arch_name>"
#        match = re.search(r'-march=\s+([^\s]+)', result.stdout)
#        if match:
#            return match.group(1).strip()
#
#    elif compiler_type == 'clang':
#        # Clang: -### (triple-hash) shows the internal command line expansion
#        # We run it against an empty input
#        cmd = [cxx, '-march=native', '-###', '-c', '-x', 'c++', '/dev/null']
#        result = subprocess.run(cmd, capture_output=True, text=True)
#        # Clang output for -### is in stderr
#        output = result.stderr
#        # Look for "-target-cpu" "name"
#        match = re.search(r'"-target-cpu"\s+"([^"]+)"', output)
#        if match:
#            return match.group(1).strip()
#
#    return 'x86-64' # Safe fallback
#
#def get_arch_flags(compiler_type: str | None = None) -> List[str]:
#    """
#    Returns specific march/mtune flags instead of generic 'native'.
#    """
#    arch = detect_native_arch(compiler_type)
#    # Most modern compilers treat march as also setting mtune,
#    # but being explicit helps for older GCC versions.
#    return [f'-march={arch}', f'-mtune={arch}']

def get_native_target_flags(compiler_type: str | None = None) -> List[str]:
    """
    Extracts the exact march and mtune targets that 'native' resolves to.
    """
    compiler_type = compiler_type or detect_compiler_type()
    cxx = shlex.split(os.environ.get('CXX') or 'g++')[0]

    if compiler_type == 'gcc':
        # GCC gives us the resolved name directly in the help output
        cmd = [cxx, '-march=native', '-Q', '--help=target']
        res = subprocess.run(cmd, capture_output=True, text=True)
        # We want the march and mtune lines
        march = re.search(r'-march=\s+(\S+)', res.stdout)
        mtune = re.search(r'-mtune=\s+(\S+)', res.stdout)

        if march and mtune:
            return [f'-march={march.group(1)}', f'-mtune={mtune.group(1)}']

    elif compiler_type == 'clang':
        # Clang is more cryptic; we have to look at the 'target-cpu' in the assembly dump
        cmd = [cxx, '-march=native', '-###', '-c', '-x', 'c++', '/dev/null']
        res = subprocess.run(cmd, capture_output=True, text=True)
        # Search stderr for "-target-cpu" "name"
        cpu_match = re.search(r'"-target-cpu"\s+"([^"]+)"', res.stderr)
        if cpu_match:
            cpu = cpu_match.group(1)
            return [f'-march={cpu}', f'-mtune={cpu}']

    return [] # Fallback if detection fails NOTE I said DISTRIBUTED build

def get_best_optimization_flags() -> List[str]:
    """
    The 'Kitchen Sink' of performance flags for a fixed-hardware target.
    """
    # 1. Start with the specific hardware architecture
    flags = get_native_target_flags()

    # 2. Add high-level optimization
    flags.extend([
    #    #'-O3',             # Aggressive optimization # NOTE -Ofast
    #    '-flto=auto',      # Link Time Optimization (huge for VA logic)
    #    #'-ffast-math',     # If your audio/ML logic can tolerate minor precision drift # NOTE mine can, but this is for building *any* simple project
    #    '-fno-plt',        # Optimization for calls to shared libraries
    ])
    #
    ## 3. Add instruction-specific safety (optional but recommended)
    ## This ensures if we have AVX2, we're definitely using it.
    #flags.append('-mavx2') # NOTE what if we don't have it ?

    return flags

def apply_build_env(afdo_path: Path|None=None) -> None:
    """
    Analyzes the hardware and AFDO state, then injects the resulting
    flags into the current process's os.environ.

    All subsequent subprocess.run/Popen calls will inherit these flags.
    """
    new_env = get_build_env(afdo_path)

    # We update os.environ in-place.
    # This affects the current process and all future children.
    os.environ.update(new_env)

    logging.info("Build environment applied to current process.")
    logging.debug(f"CFLAGS: {os.environ.get('CFLAGS')}")
    logging.debug(f"CXXFLAGS: {os.environ.get('CXXFLAGS')}")

def main()->None:
    print(get_cflags(Path() / 'test.afdo'))

if __name__ == '__main__':
    main()
