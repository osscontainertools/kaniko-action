target "app" {
  target      = "app"
  destination = ["registry.invalid/app"]
}

target "tools" {
  target      = "tools"
  destination = ["registry.invalid/tools"]
}

target "unselected" {
  target      = "app"
  destination = ["registry.invalid/unselected"]
}
