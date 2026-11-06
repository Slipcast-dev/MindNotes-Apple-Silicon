"""Small demo for syntax highlighting."""
import json
from dataclasses import dataclass


@dataclass
class Task:
    title: str
    done: bool = False


def summary(tasks: list[Task]) -> str:
    finished = sum(1 for t in tasks if t.done)  # count completed
    return f"{finished}/{len(tasks)} done"


if __name__ == "__main__":
    print(summary([Task("write docs", True), Task("ship 1.0")]))
