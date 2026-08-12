"""Language adapters justified by the current Rift worktree."""

from .c_family import CLikeAdapter, JavaAdapter
from .csharp import CSharpAdapter
from .dart import DartAdapter
from .kotlin import KotlinAdapter
from .python import PythonAdapter
from .swift import SwiftAdapter


DEFAULT_ADAPTERS = (
    CSharpAdapter(),
    DartAdapter(),
    PythonAdapter(),
    KotlinAdapter(),
    SwiftAdapter(),
    JavaAdapter(),
    CLikeAdapter(),
)

__all__ = [
    "CLikeAdapter",
    "CSharpAdapter",
    "DartAdapter",
    "JavaAdapter",
    "KotlinAdapter",
    "PythonAdapter",
    "SwiftAdapter",
    "DEFAULT_ADAPTERS",
]
