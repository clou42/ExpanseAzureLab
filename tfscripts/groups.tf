# Old version just as a backup.
# resource "azuread_group" "rocinante" {
#   display_name = "Rocinante"
#   security_enabled = true
# }

# resource "azuread_group_member" "rocinante" {
#   for_each = { for u in azuread_user.users: u.mail_nickname => u if u.department == "Rocinante" }

#   group_object_id  = azuread_group.rocinante.id
#   member_object_id = each.value.id
#   depends_on = [
#     azuread_user.users
#   ]
# }

# resource "azuread_group" "captains" {
#   display_name = "Captains"
#   security_enabled = true
# }

# resource "azuread_group_member" "captains" {
#   for_each = { for u in azuread_user.users: u.mail_nickname => u if u.job_title == "Captain" }

#   group_object_id  = azuread_group.captains.id
#   member_object_id = each.value.id
#   depends_on = [
#     azuread_user.users
#   ]
# }

# resource "azuread_group" "pilots" {
#   display_name = "Pilot"
#   security_enabled = true
# }

# resource "azuread_group_member" "pilots" {
#   for_each = { for u in azuread_user.users: u.mail_nickname => u if u.job_title == "Pilot" }

#   group_object_id  = azuread_group.pilots.id
#   member_object_id = each.value.id
#   depends_on = [
#     azuread_user.users
#   ]
# }

# resource "azuread_group" "crew" {
#   display_name = "Crew"
#   security_enabled = true
# }

# resource "azuread_group_member" "crew" {
#   for_each = { for u in azuread_user.users: u.mail_nickname => u if u.job_title == "Crew" }

#   group_object_id  = azuread_group.crew.id
#   member_object_id = each.value.id
#   depends_on = [
#     azuread_user.users
#   ]
# }
locals {
  job_titles_to_group = [
    "Captain-${var.config.lab_uniq_id}",
    "Pilot-${var.config.lab_uniq_id}",
    "Crew-${var.config.lab_uniq_id}",
    "Engineer-${var.config.lab_uniq_id}",
    "Commander-${var.config.lab_uniq_id}",
    "Gunnery Sergeant-${var.config.lab_uniq_id}",
    "Detective-${var.config.lab_uniq_id}",
    "Civilian Technician-${var.config.lab_uniq_id}",
    "Secretary-General-${var.config.lab_uniq_id}"
  ]

  departments_to_group = [
    "Rocinante-${var.config.lab_uniq_id}",
    "UN-${var.config.lab_uniq_id}",
    "OPA-${var.config.lab_uniq_id}",
    "Martian Navy-${var.config.lab_uniq_id}",
    "Free Navy-${var.config.lab_uniq_id}",
    "Star Helix-${var.config.lab_uniq_id}",
  ]
}

# Create groups based on job titles
resource "azuread_group" "job_groups" {
  for_each         = toset(local.job_titles_to_group)
  display_name     = each.key
  security_enabled = true
}

# Add users to job title groups
resource "azuread_group_member" "job_group_members" {
  for_each = {
    for user in azuread_user.users : "${user.mail_nickname}-${user.job_title}" => {
      user      = user
      job_title = user.job_title
    }
    if contains(local.job_titles_to_group, user.job_title)
  }

  group_object_id  = basename(azuread_group.job_groups[each.value.job_title].id)
  member_object_id = basename(each.value.user.id)
  depends_on       = [azuread_user.users]
}

# Create groups based on departments
resource "azuread_group" "department_groups" {
  for_each         = toset(local.departments_to_group)
  display_name     = each.key
  security_enabled = true
}

# Add users to department groups
resource "azuread_group_member" "department_group_members" {
  for_each = {
    for user in azuread_user.users : "${user.mail_nickname}-${user.department}" => {
      user       = user
      department = user.department
    }
    if contains(local.departments_to_group, user.department)
  }

  group_object_id  = basename(azuread_group.department_groups[each.value.department].id)
  member_object_id = basename(each.value.user.id)
  depends_on       = [azuread_user.users]
}

# Add service principals to department groups (mirroring user logic)
resource "azuread_group_member" "sp_department_group_members" {
  for_each = {
    for key, sp in azuread_service_principal.sp :
    "${sp.client_id}-${local.users_map[key].department}" => {
      sp         = sp
      department = format("%s-%s", local.users_map[key].department, var.config.lab_uniq_id)
      user_key   = key
    }
    if contains(local.departments_to_group, format("%s-%s", local.users_map[key].department, var.config.lab_uniq_id))
  }

  group_object_id  = basename(azuread_group.department_groups[each.value.department].id)
  member_object_id = basename(each.value.sp.object_id)
  depends_on       = [azuread_service_principal.sp]
}

# Add service principals to job title groups (mirroring user logic)
resource "azuread_group_member" "sp_job_group_members" {
  for_each = {
    for key, sp in azuread_service_principal.sp :
    "${sp.client_id}-${local.users_map[key].job_title}" => {
      sp        = sp
      job_title = format("%s-%s", local.users_map[key].job_title, var.config.lab_uniq_id)
      user_key  = key
    }
    if contains(local.job_titles_to_group, format("%s-%s", local.users_map[key].job_title, var.config.lab_uniq_id))
  }

  group_object_id  = basename(azuread_group.job_groups[each.value.job_title].id)
  member_object_id = basename(each.value.sp.object_id)
  depends_on       = [azuread_service_principal.sp]
}
