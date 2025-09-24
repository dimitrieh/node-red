![logo](https://github.com/user-attachments/assets/b0c8ce6b-1d9e-4e15-a15f-bc3babd5ec84)

# Node-RED Experimentation Repository

This repository is part of the Node-RED Modernization Project and is used to create experimental versions of Node-RED for fast iterative designing and to aid in implementating any approved changes as a result of testing.

For more information on the Node-RED Modernization Project please see this [Node-RED Forum post](https://discourse.nodered.org/t/initiating-a-modernization-project-for-node-red/59597).

**Note:** This repsitory is public but not interactable. Please reach out through the [official Node-RED issue tracker](https://dashboard.tailbfedba.ts.net/) for any inquieries or feedback for now.

## Workflow

- This repository has been optimised so that you can develop locally using the default Node-RED development workflow or by using AI workflows in Github actions triggered in issues and pull requests.
- Upon deployment all unnecessary files are ignored, demo mode activated, and a specific docker image is generated.
- Generation of docker images and deployment of containers is done on a VM with [Tailscale](https://tailscale.com/) as the reverse proxy manager and monitor.
- Each live Node-RED instance has "sandbox mode" active for safe public demo access.
- The [dashboard](https://dashboard.tailbfedba.ts.net/) gets updated and deployed after every push as well.

**Note:** There are a lot of optimisations to be done. Most code and workflows in this repository and the experiments it created should be considered experimental code at best, not production code. This is a repository meant for iterative design experimentation together with the open-source community of [Node-RED](https://nodered.org/).

## Copyright and license

Copyright OpenJS Foundation and other contributors, https://openjsf.org under [the Apache 2.0 license](LICENSE).
