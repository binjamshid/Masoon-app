# Contributing to Masoon

Code, documentation, Arabic and English translations, and sourced corrections to learning material are welcome. For help using the app, see [Support](SUPPORT.md). Send privacy or security reports to the [private reporting channel](SECURITY.md). The [code of conduct](CODE_OF_CONDUCT.md) applies to issues and reviews.

## Fork and propose a change

1. **Read the source license.** This repository is the public source distribution. Read the [license](LICENSE) and the public-fork obligations below before modifying covered software.
2. **Choose the scope.** Open an issue for changes that affect curriculum behavior, shared data formats, permissions, new dependencies or new content sources. For a small correction, open a PR directly. For a text correction, follow the [content guide](docs/content-contributions.md).
3. **Create a topic branch in your fork.** On GitHub select **Fork** on the upstream repository, then clone your fork. With GitHub CLI the equivalent from outside a checkout is:

   ```sh
   gh repo fork binjamshid/Masoon-app --clone
   cd Masoon-app
   git switch -c fix/planner-documentation
   ```

4. **Keep the change reviewable.** Use synthetic fixtures. Include each changed input and the generated copies the project checks in. Preserve original author credits, copyrights and upstream notices. Refer to [development](docs/development.md), [testing](docs/testing.md), and [third-party notices](THIRD_PARTY_NOTICES.md).
5. **Submit to upstream `main`.** Commit the intended files on the topic branch, push the branch to your fork, then open a PR. For example, after committing:

   ```sh
   git push -u origin HEAD
   gh pr create --repo binjamshid/Masoon-app --base main
   ```

   Describe what someone will observe, the platforms affected, and the checks you ran. Identify remaining device, asset or service dependencies. A maintainer reviews the change before integration. The applicable GitHub rules and release authority are described in [Governance](GOVERNANCE.md).

## Obligations for a covered public release

The [license](LICENSE) controls. Here is how to apply it when you change publicly released covered software.

- Publish the editable source of **each modified version** on any publicly accessible version-control host under the exact same license. Local, uncommitted, abandoned, and internal changes are included. Contributing upstream is optional. An upstream PR alone may omit intermediate versions or disappear.
- Publish within **30 calendar days of the change**, or **before first distributing the version or letting others use it as a service**, whichever comes first. A batch is acceptable when each version can be recovered on time.
- Keep each version downloadable without registration while you distribute or provide that version as a service, and for at least **12 months after first publication**. Give recipients and service users a link to the corresponding source.
- Include the build instructions, scripts and dependency information needed to reproduce the modified software. Keep secrets, personal data, private configuration and third-party private material out of the repository. Use safe placeholders. For an independently available third-party dependency, identify its publisher and version as permitted by the license.
- Commercial use by or on behalf of a for-profit organization is restricted under section 3. The license permits optional financial support for otherwise permitted work. Include the license and applicable notices when distributing source or binaries, identify your changes, and observe the separate terms for third-party material.
- If publishing a fix would expose an unremediated vulnerability, notify the maintainer privately. Apply the coordinated time limit in section 4 and the [security policy](SECURITY.md).

## Terms for submissions

By submitting work you own for inclusion, you agree that the project may distribute that contribution under the Binjamshid Public Fork License, Version 1.0, as part of an owner-authorized public release. You keep your copyright. Identify any third-party material and its original terms, provide the source and reuse evidence, and preserve its notices. The maintainer may omit material whose rights are unclear.

Describe your own work in the commit and PR. Keep author and contributor fields accurate. For content involving scripture or commentary, include the edition and reference so reviewers can verify the change independently.
