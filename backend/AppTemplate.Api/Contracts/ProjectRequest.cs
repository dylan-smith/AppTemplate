using System.ComponentModel.DataAnnotations;

namespace AppTemplate.Api.Contracts;

public class ProjectRequest
{
    [Required]
    [MaxLength(200)]
    public string Name { get; set; } = string.Empty;
}
