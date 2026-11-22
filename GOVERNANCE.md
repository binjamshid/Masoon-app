# How Masoon is maintained

The repository owner, **@binjamshid**, decides which changes enter the upstream project, selects release revisions, and authorizes official distributions and use of the Masoon name. Contributors retain copyright in their own work. Anyone working from a covered public release can maintain an independent fork under the [license](LICENSE). Identify unofficial builds clearly.

## Reviews and decisions

| Change | Evidence the maintainer looks for |
| --- | --- |
| Client interface or accessibility | Platform, language/direction, affected screen, and a focused check or sanitized illustration of the change. |
| Curriculum or planner behavior | The expected learning outcome, the curriculum rule, and the shared fixture or parity evidence across affected implementations. |
| Sacred text, commentary or audio | The edition and precise reference, publisher and reuse terms, and a qualified language or subject reviewer where interpretation is involved. The maintainer can defer a correction pending verification. |
| Shared API, persistence or sync | Compatibility with existing clients and local data, contract changes, and focused test evidence. |
| Public distribution | The exact source revision, authorized rights scope, notices and any omitted assets or unavailable features. |

Discuss changes to established behavior in an issue or PR. Record the rationale, decision and affected contracts alongside the accepted implementation. A feature proposal or merged change does not promise a release date.

## Rules on upstream main

External contributors work in forks and open pull requests. GitHub requires a pull request for changes to `main`, one approving review on the normal merge path, and resolution of review conversations. New reviewable commits dismiss stale approvals. Force pushes and deletion of `main` are blocked. The repository administrator can use a **pull-request-only bypass**, allowing the sole maintainer to merge their own PR without a second account. Only grant upstream write access to a person trusted to maintain the project. GitHub can accept a PR from an upstream topic branch as well as a fork.

Select focused checks according to the files you change. Include your local results in the PR. The owner manages official release signing and production services. See the [release guide](docs/public-releases.md).
