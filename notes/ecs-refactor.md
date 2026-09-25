### Refactor
The current codebase is a product of the reverse engineering and slow decline in quality and mixing of responsibilities result of features being added and small corrections being made.

### Proposal
- work on reaching 100% behavioural matching test coverage for simulation code
- Introduce ode-ecs, a third party ECS framework which will allow us to decouple our data and behaviours by abstracting them into ECS components and systems respectively.
    - this will make the code far more maintainable, easier to extend, etc
- Split new content added by deimos rose into "plugins" which can depend on eachother where required, a mods screen accessable through preferences will allow for enabling / disabling these plugins, for example (sub bullets are examples of direct dependencies)
- Easy Mode Plugin
    - Passive Upgrades Plugin
- New Weapons Plugin
    - Extra Preferences Plugin
    - Loadout Plugin
- Accent Color Plugin
    - Extra Preferences Plugin
- Netplay Plugin
- Loadout Plugin
    - Extra Preferences Plugin
- Passive Upgrades Plugin
    - Extra Preferences Plugin
- 30FPS Unlock Plugin
    - Extra Preferences Plugin
- Extra Preferences Plugin

The extra preferences plugin will allow mods to register settings which will appear on the Extra preferences page, this page will be populated with all registered extra preferences in a scrollable list

### ECS Usage
- Entities are simple ids, with a collection of components
- All simulation state must be stored in the ECS world as components on entities to remain deterministic and serializable for netplay / rollback
- Only systems will act on state, systems may depend on other systems.
    - if system A depends on system B, that indicates not that system A is accessing any data exported by system B, but rather than in the update loop system A comes after system B.
- Systems should have single responsibilities and query small sets of components wherever possible, for example:
    - A movement system which takes entities with velocity vector's and moves them to their new positions

As a result of all simulation being moved into ECS, rendering of this state will need to move to systems also, but in a seperate loop from the simulation update. A good example of a small render system would be a system that renders outlines for ships as configured by the plugin, this system would only be added to the render loop when the plugin is enabled.

Plugins should live in their own folders that are self contained as much as possible, users should be able to develop new plugins that register their own new components and systems.

System dependency is a bit different from plugin dependencies, plugin dependencies can access components exported by other plugins, systems dependencies are about the order which systems are run.

### Notes
- it will be difficult to refactor small parts of the system at once, we will need to do a broad refactor first, then seek to restore accuracy afterwards.