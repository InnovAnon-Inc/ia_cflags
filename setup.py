import sysconfig, shlex, os
from setuptools import find_packages, Extension, setup as _setup
from Cython.Build import cythonize

def merge_compiler_flags() -> None:
    """
    Parses current and env flags into a key-value map to handle overrides 
    (e.g., -O2 -> -O3) and ensures 'Last-In-Wins' behavior.
    """
    target_keys = ['OPT', 'CFLAGS', 'PY_CFLAGS', 'PY_CORE_CFLAGS', 'CONFIGURE_CFLAGS', 'LDSHARED']
    cvars = sysconfig.get_config_vars()

    def tokenize_to_dict(flag_list):
        """Converts flags into a dict for easy overriding."""
        result = {}
        for f in flag_list:
            if f.startswith('-O'):
                result['-O'] = f
            elif f.startswith('-march='):
                result['-march'] = f
            elif f.startswith('-mtune='):
                result['-mtune'] = f
            elif f.startswith('-g'):
                result['-g'] = f
            else:
                result[f] = None
        return result
    env_flags = shlex.split(os.environ.get('CFLAGS', ''))
    env_overrides = tokenize_to_dict(env_flags)
    for key in target_keys:
        if key not in cvars:
            continue
        current_flags = shlex.split(cvars[key])
        flag_dict = tokenize_to_dict(current_flags)
        flag_dict.update(env_overrides)
        final_flags = [f if v is None else v for f, v in flag_dict.items()]
        cvars[key] = ' '.join(final_flags)

def setup(*args, **kwargs) -> None:
    merge_compiler_flags()
    _kwargs = dict(kwargs)
    if 'packages' not in kwargs:
        _kwargs['packages'] = find_packages()
    if 'ext_modules' not in kwargs:
        _kwargs['ext_modules'] = cythonize([Extension('*', ['**/*.pyx'], language='c++')], compiler_directives={'language_level': '3'}, build_dir='build')
    if 'exclude_package_data' not in kwargs:
        _kwargs['exclude_package_data'] = {'': ['*.cpp', '*.pyx', '*.py', '*.pxd', '*.h', '*.afdo', 'hook-*.py', 'bootstrap-*.py', '*.spec', '__pycache__', '.env']}
    _setup(*args, **_kwargs)
if __name__ == '__main__':
    setup(use_scm_version=True, setup_requires=['setuptools_scm'])