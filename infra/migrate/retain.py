#!/usr/bin/env python3
"""Step 3a: adds DeletionPolicy: Retain and UpdateReplacePolicy: Retain to every resource of
the three CloudFormation templates, so that deleting the stacks leaves the real resources.

    python3 infra/migrate/retain.py infra/auth.yaml infra/reports.yaml infra/ai.yml

Then deploy each stack once more WITHOUT changing parameters (they keep their old values):

    aws cloudformation deploy --stack-name <project>-reports --template-file infra/reports.yaml \\
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset
"""

import re
import sys

for path in sys.argv[1:]:
    text = open(path, newline="").read()
    eol = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(eol)
    out: list[str] = []
    in_resources = False
    block: list[str] = []

    def flush() -> None:
        if block and not any("DeletionPolicy" in line for line in block):
            for i, line in enumerate(block):
                if re.match(r"^    Type: ", line):
                    block[i + 1 : i + 1] = [
                        "    DeletionPolicy: Retain",
                        "    UpdateReplacePolicy: Retain",
                    ]
                    break
        out.extend(block)
        block.clear()

    for line in lines:
        if re.match(r"^[A-Za-z]", line):  # a top-level key
            flush()
            in_resources = line.startswith("Resources:")
            out.append(line)
        elif in_resources and re.match(r"^  [A-Za-z0-9]+:\s*$", line):  # a resource header
            flush()
            block.append(line)
        elif in_resources and block:
            block.append(line)
        else:
            out.append(line)
    flush()
    open(path, "w", newline="").write(eol.join(out))
    print(f"{path}: Retain added")
