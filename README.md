# Masoon-app · مصون

Masoon is an Arabic-first memorization planner. This public source edition contains the planning engines used to turn a curriculum, a learner’s starting point, and a calendar into daily tasks. It also includes mobile interface examples, shared data contracts and selected offline sync logic.

مصون تطبيق لتنظيم الحفظ والمراجعة. يضم هذا المستودع شيفرة محرك التخطيط، وأمثلة لواجهات الهاتف، وعقود البيانات المشتركة. يمكنك تجربة التخطيط محليًا ببيانات تدريبية دون حساب أو اتصال بخدمات مصون.

## Try the planner

With Deno 2 installed, run this command from the repository root. It schedules six lines of an original sample poem over three evenings. The inputs are local files. No account or network access is required.

```sh
deno run --no-config --no-remote --no-prompt --allow-read=backend/examples/synthetic-plan backend/engine/fixture_runner.ts backend/examples/synthetic-plan
```

The output contains five task rows followed by a final state with `status=completed`. Change the pace or study window in the example to see how the plan changes. [Example and field guide](backend/README.md)

## Explore the source

| Area | Entry point |
| --- | --- |
| Swift domain, curriculum engine and watch models | [Swift packages and fixture runner](apps/ios/README.md) |
| Kotlin domain and curriculum engine | [Kotlin modules and fixture runner](apps/android/README.md) |
| Mobile interface examples | [SwiftUI components](mobile-ui/ios/README.md) · [Android weekly board](mobile-ui/android/README.md) |
| TypeScript planner and sync logic | [Planner](backend/README.md) · [Sync](backend/sync/README.md) |
| Shared contracts and technical blueprints | [Contracts](contracts/README.md) · [Architecture](docs/architecture/README.md) |
| Working on a change | [Development](docs/development.md) · [Testing](docs/testing.md) · [Contributing](CONTRIBUTING.md) |
| Using the distributed app | [English and Arabic user guide](docs/user-guide.md) · [Releases](docs/public-releases.md) · [Support](SUPPORT.md) |

## What is included

This source edition can run the planner with fictional data and exercise the selected components independently. The official store apps also use edition-specific text, page layouts, fonts, reference databases, reciter media and hosted services. Those resources, the production mobile shells, signing and account infrastructure, and unreleased integrations are outside this distribution. The component examples do not reproduce a store binary. Use the [asset guide](docs/legal/asset-inventory.md) when supplying your own inputs.

## License and forks

The owner releases the covered Masoon source here under the **Binjamshid Public Fork License, Version 1.0**. This is a source-available license. It restricts commercial use by or on behalf of for-profit organizations. Modifications, including local changes, carry public-source obligations and deadlines. Read the [exact license](LICENSE) and [fork rules](CONTRIBUTING.md) before editing or distributing the software. Third-party rights and the limits on use of the Masoon name are described in [Third-party notices](THIRD_PARTY_NOTICES.md).
