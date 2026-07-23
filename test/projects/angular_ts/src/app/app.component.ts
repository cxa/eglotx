import { Component } from "@angular/core";

@Component({
  selector: "eglotx-root",
  standalone: true,
  template: `
    <h1>{{ title }}</h1>
    <p>{{ missingTemplateProperty }}</p>
  `,
})
export class AppComponent {
  readonly title = "Eglotx";
  readonly typeProbe: string = 42;
}
