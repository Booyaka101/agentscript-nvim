# Security Policy

## Supported versions

`main` is the only supported branch. There are no maintenance branches.

## Reporting a vulnerability

Please **don't** open a public issue for a security problem.

Use GitHub's [private vulnerability reporting](https://github.com/Booyaka101/agentscript-nvim/security/advisories/new) instead. Expect a first response within a week.

Please include what you found, how to reproduce it, and what an attacker gets out of it.

## What this touches

A Neovim plugin. It reads Agent Script files and talks to the language server; it does not run your agents.

- **It runs inside your editor** and starts the Agent Script language server on the files you open. It does not run your agents.
- **Project-local configuration is honoured.** Opening an untrusted repository is the main risk surface here, as with any LSP setup.

## Scope

In scope: anything that leaks a credential, reads data belonging to someone else, or lets untrusted input reach code execution.

Out of scope: findings that require an attacker to already control the machine it runs on.
